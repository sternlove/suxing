/**
 * libllamaohos.so —— CyberTwin 的 llama.cpp NAPI 桥接层。
 *
 * 对外契约（由 entry/src/main/cpp/types/libllamaohos/index.d.ts 声明）：
 *   createContext() -> number
 *   loadModel(handle, path) -> boolean
 *   generateStream(handle, prompt, callback) -> void
 *   cancel(handle) -> void
 *   releaseContext(handle) -> void
 *
 * 另外把上面 5 个函数挂到一个名为 LlamaNative 的对象上一起导出，
 * 以匹配 ArkTS 侧 import { LlamaNative } from 'libllamaohos.so' 的既有写法。
 *
 * 线程模型：
 *   生成在 std::thread 里跑（llama.cpp 的 token 回调不落在 ArkTS 主线程），
 *   每产出一次文本就通过 napi threadsafe function 送回主线程，
 *   回调参数是「累计全文」——Index.ets 是整段替换渲染的。
 */

#include <hilog/log.h>
#include <napi/native_api.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "llama.h"

namespace {

// 推理参数的缺省值（ArkTS 侧 loadModel 的 options 可覆写）
constexpr int32_t kDefaultNCtx     = 2048;
constexpr int32_t kDefaultNBatch   = 512;
constexpr int32_t kDefaultNPredict = 512;

// hilog：真机上用 hdc shell hilog -T LlamaOhos 过滤
constexpr unsigned int kLogDomain = 0x0C7B;
constexpr const char * kLogTag    = "LlamaOhos";

#define CT_LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)
#define CT_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)
#define CT_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)

// generateStream 的结束码，和 ArkTS 侧 LlamaBridge 的约定一致
constexpr int32_t kExitOk       = 0;
constexpr int32_t kExitCanceled = 1;
constexpr int32_t kExitError    = 2;

struct Session {
    // mu 保护 model/ctx/vocab 的创建与销毁，以及 worker 的 join。
    // canceling/busy 是原子量，worker 线程无锁读写。
    std::mutex          mu;
    llama_model *       model = nullptr;
    llama_context *     ctx   = nullptr;
    const llama_vocab * vocab = nullptr;

    std::thread         worker;
    std::atomic<bool>   canceling{false};
    std::atomic<bool>   busy{false};

    // 推理参数：ArkTS 侧 loadModel(handle, path, options) 可覆写，缺省用编译期常量
    int32_t             n_ctx     = kDefaultNCtx;
    int32_t             n_batch   = kDefaultNBatch;
    int32_t             n_predict = kDefaultNPredict;
    int32_t             n_threads = 0; // 0 = 按 CPU 核数自动

    // 采样参数：temperature <= 0 时走贪心（与旧行为逐位一致），否则构建采样链
    float               temperature = 0.0f;
    float               top_p       = 1.0f;
    float               min_p       = 0.0f;
    int32_t             top_k       = 0;
    uint32_t            seed        = 0;
};

// g_sessions 持 shared_ptr：worker 线程各自持一份引用，
// 于是 releaseContext 与正在跑的生成之间不会出现 use-after-free。
std::mutex                                          g_mutex;
std::map<int64_t, std::shared_ptr<Session>>         g_sessions;
int64_t                                             g_next_handle = 1;
std::once_flag                                      g_backend_once;

void EnsureBackend() {
    std::call_once(g_backend_once, []() { llama_backend_init(); });
}

std::shared_ptr<Session> FindSession(int64_t handle) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_sessions.find(handle);
    if (it == g_sessions.end()) {
        return nullptr;
    }
    return it->second;
}

napi_value OkValue(napi_env env) {
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value MakeBoolean(napi_env env, bool value) {
    napi_value result = nullptr;
    if (napi_get_boolean(env, value, &result) != napi_ok) {
        return OkValue(env);
    }
    return result;
}

// ---- 参数校验：不合法一律抛 JS 异常，绝不以 nullptr/false 静默吞掉 ----

void ThrowType(napi_env env, const char * fn, const char * what) {
    char msg[192];
    snprintf(msg, sizeof(msg), "%s: 参数 %s 类型不正确", fn, what);
    CT_LOGE("%{public}s", msg);
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", msg);
}

void ThrowRange(napi_env env, const char * fn, const char * what, int64_t value) {
    char msg[192];
    snprintf(msg, sizeof(msg), "%s: 参数 %s 取值非法（%lld）", fn, what, static_cast<long long>(value));
    CT_LOGE("%{public}s", msg);
    napi_throw_range_error(env, "ERR_INVALID_ARG_VALUE", msg);
}

void ThrowNapi(napi_env env, const char * fn, const char * what, napi_status status) {
    char msg[192];
    snprintf(msg, sizeof(msg), "%s: NAPI 调用失败 %s (status=%d)", fn, what, static_cast<int>(status));
    CT_LOGE("%{public}s", msg);
    napi_throw_error(env, "ERR_NAPI", msg);
}

void ThrowHandle(napi_env env, const char * fn, int64_t handle) {
    char msg[192];
    snprintf(msg, sizeof(msg), "%s: 无效的 handle=%lld（未创建或已释放）", fn,
             static_cast<long long>(handle));
    CT_LOGE("%{public}s", msg);
    napi_throw_error(env, "ERR_INVALID_HANDLE", msg);
}

void ThrowError(napi_env env, const char * code, const char * msg) {
    CT_LOGE("%{public}s", msg);
    napi_throw_error(env, code, msg);
}

bool RequireArgc(napi_env env, size_t argc, size_t need, const char * fn) {
    if (argc >= need) {
        return true;
    }
    char msg[192];
    snprintf(msg, sizeof(msg), "%s: 至少需要 %zu 个参数，实际收到 %zu 个", fn, need, argc);
    CT_LOGE("%{public}s", msg);
    napi_throw_type_error(env, "ERR_MISSING_ARGS", msg);
    return false;
}

bool ArgHandle(napi_env env, napi_value value, const char * fn, int64_t * out) {
    napi_valuetype type = napi_undefined;
    const napi_status st = napi_typeof(env, value, &type);
    if (st != napi_ok) {
        ThrowNapi(env, fn, "napi_typeof(handle)", st);
        return false;
    }
    if (type != napi_number) {
        ThrowType(env, fn, "handle");
        return false;
    }
    double raw = 0;
    const napi_status st2 = napi_get_value_double(env, value, &raw);
    if (st2 != napi_ok) {
        ThrowNapi(env, fn, "napi_get_value_double(handle)", st2);
        return false;
    }
    if (raw <= 0) {
        ThrowRange(env, fn, "handle", static_cast<int64_t>(raw));
        return false;
    }
    *out = static_cast<int64_t>(raw);
    return true;
}

bool ArgString(napi_env env, napi_value value, const char * fn, const char * what, std::string * out) {
    napi_valuetype type = napi_undefined;
    const napi_status st = napi_typeof(env, value, &type);
    if (st != napi_ok) {
        ThrowNapi(env, fn, "napi_typeof(string)", st);
        return false;
    }
    if (type != napi_string) {
        ThrowType(env, fn, what);
        return false;
    }
    size_t length = 0;
    const napi_status st1 = napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    if (st1 != napi_ok) {
        ThrowNapi(env, fn, "napi_get_value_string_utf8(len)", st1);
        return false;
    }
    std::vector<char> buffer(length + 1, '\0');
    size_t copied = 0;
    const napi_status st2 = napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied);
    if (st2 != napi_ok) {
        ThrowNapi(env, fn, "napi_get_value_string_utf8(data)", st2);
        return false;
    }
    *out = std::string(buffer.data(), copied);
    return true;
}

std::shared_ptr<Session> RequireSession(napi_env env, int64_t handle, const char * fn) {
    std::shared_ptr<Session> session = FindSession(handle);
    if (session == nullptr) {
        ThrowHandle(env, fn, handle);
    }
    return session;
}

// 从 ArkTS 的 options 对象读一个整数项：缺失则保持默认，类型/范围不对就抛异常
bool ReadIntOption(napi_env env, napi_value obj, const char * key, const char * fn,
                   int32_t min_value, int32_t max_value, int32_t * out) {
    napi_value prop = nullptr;
    const napi_status st = napi_get_named_property(env, obj, key, &prop);
    if (st != napi_ok) {
        ThrowNapi(env, fn, "napi_get_named_property", st);
        return false;
    }
    napi_valuetype type = napi_undefined;
    const napi_status tst = napi_typeof(env, prop, &type);
    if (tst != napi_ok) {
        ThrowNapi(env, fn, "napi_typeof(option)", tst);
        return false;
    }
    if (type == napi_undefined || type == napi_null) {
        return true;
    }
    if (type != napi_number) {
        ThrowType(env, fn, key);
        return false;
    }
    double raw = 0;
    const napi_status vst = napi_get_value_double(env, prop, &raw);
    if (vst != napi_ok) {
        ThrowNapi(env, fn, "napi_get_value_double(option)", vst);
        return false;
    }
    const int32_t value = static_cast<int32_t>(raw);
    if (value < min_value || value > max_value) {
        char what[64];
        snprintf(what, sizeof(what), "%s（允许 %d..%d）", key, min_value, max_value);
        ThrowRange(env, fn, what, value);
        return false;
    }
    *out = value;
    return true;
}

bool ReadFloatOption(napi_env env, napi_value obj, const char * key, const char * fn,
                     double min_value, double max_value, float * out) {
    napi_value prop = nullptr;
    const napi_status st = napi_get_named_property(env, obj, key, &prop);
    if (st != napi_ok) {
        ThrowNapi(env, fn, "napi_get_named_property", st);
        return false;
    }
    napi_valuetype type = napi_undefined;
    const napi_status tst = napi_typeof(env, prop, &type);
    if (tst != napi_ok) {
        ThrowNapi(env, fn, "napi_typeof(option)", tst);
        return false;
    }
    if (type == napi_undefined || type == napi_null) {
        return true;
    }
    if (type != napi_number) {
        ThrowType(env, fn, key);
        return false;
    }
    double raw = 0;
    const napi_status vst = napi_get_value_double(env, prop, &raw);
    if (vst != napi_ok) {
        ThrowNapi(env, fn, "napi_get_value_double(option)", vst);
        return false;
    }
    if (raw < min_value || raw > max_value) {
        char what[64];
        snprintf(what, sizeof(what), "%s（允许 %g..%g）", key, min_value, max_value);
        ThrowError(env, "ERR_INVALID_ARG_VALUE", what);
        return false;
    }
    *out = static_cast<float>(raw);
    return true;
}

// 采样器构建：默认贪心；temperature > 0 时按 top_k/top_p/min_p/temp 组链
llama_sampler * BuildSampler(const Session & session) {
    if (session.temperature <= 0.0f) {
        return llama_sampler_init_greedy();
    }
    llama_sampler_chain_params params = llama_sampler_chain_default_params();
    params.no_perf = true;
    llama_sampler * chain = llama_sampler_chain_init(params);
    if (chain == nullptr) {
        return nullptr;
    }
    if (session.top_k > 0) {
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(session.top_k));
    }
    if (session.top_p < 1.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(session.top_p, 1));
    }
    if (session.min_p > 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(session.min_p, 1));
    }
    llama_sampler_chain_add(chain, llama_sampler_init_temp(session.temperature));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(session.seed));
    return chain;
}

// ---- threadsafe function: 把累计文本与「生成结束」信号送回 ArkTS 主线程 ----

// 单条 TSFN 队列同时承载 token 与 done 两种消息，FIFO 保证 done 一定在所有
// token 之后到达，ArkTS 侧才不会因为乱序把最终文本覆盖成半截。
enum PayloadKind : int32_t {
    kPayloadToken = 0,
    kPayloadDone  = 1,
};

struct StreamPayload {
    PayloadKind kind;
    int32_t     code; // 仅 done 有效：0 正常 / 1 取消 / 2 出错
    std::string text;
};

struct StreamCtx {
    napi_ref done_ref = nullptr; // ArkTS 传入的 onDone
};

void FinalizeStreamCtx(napi_env env, void * finalize_data, void * /*hint*/) {
    StreamCtx * ctx = static_cast<StreamCtx *>(finalize_data);
    if (ctx == nullptr) {
        return;
    }
    if (ctx->done_ref != nullptr && env != nullptr) {
        napi_delete_reference(env, ctx->done_ref);
    }
    delete ctx;
}

void CallJs(napi_env env, napi_value js_cb, void * context, void * data) {
    std::unique_ptr<StreamPayload> payload(static_cast<StreamPayload *>(data));
    if (!payload || env == nullptr) {
        return;
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);

    if (payload->kind == kPayloadToken) {
        if (js_cb == nullptr) {
            CT_LOGW("call_js token dropped: js_cb is null (chars=%{public}zu)", payload->text.size());
            return;
        }
        napi_value argv[1] = {nullptr};
        napi_create_string_utf8(env, payload->text.c_str(), payload->text.size(), &argv[0]);
        const napi_status call_st = napi_call_function(env, undefined, js_cb, 1, argv, nullptr);
        CT_LOGI("call_js token chars=%{public}zu status=%{public}d", payload->text.size(),
                static_cast<int>(call_st));
        return;
    }

    StreamCtx * ctx = static_cast<StreamCtx *>(context);
    if (ctx == nullptr || ctx->done_ref == nullptr) {
        CT_LOGW("call_js done dropped: ctx/done_ref null (code=%{public}d chars=%{public}zu)",
                payload->code, payload->text.size());
        return;
    }
    napi_value done_fn = nullptr;
    if (napi_get_reference_value(env, ctx->done_ref, &done_fn) != napi_ok || done_fn == nullptr) {
        CT_LOGW("call_js done dropped: get_reference_value failed (code=%{public}d)", payload->code);
        return;
    }
    napi_value argv[2] = {nullptr, nullptr};
    napi_create_int32(env, payload->code, &argv[0]);
    napi_create_string_utf8(env, payload->text.c_str(), payload->text.size(), &argv[1]);
    const napi_status done_st = napi_call_function(env, undefined, done_fn, 2, argv, nullptr);
    CT_LOGI("call_js done code=%{public}d chars=%{public}zu status=%{public}d", payload->code,
            payload->text.size(), static_cast<int>(done_st));
}

// session 以 shared_ptr 传入：即使 ArkTS 侧此时调了 releaseContext，
// Session 对象也会活到本线程退出为止（releaseContext 会先 join 再释放 ctx）。
void GenerationWorker(std::shared_ptr<Session> session, std::string prompt, napi_threadsafe_function tsfn) {
    llama_context *     ctx   = session->ctx;
    const llama_vocab * vocab = session->vocab;

    std::string accumulated;
    bool ok = false;
    bool failed = false;
    CT_LOGI("worker start prompt_chars=%{public}zu", prompt.size());

    // 每次生成都从干净 KV cache 开始，否则上一轮的对话会污染这一轮的注意力
    if (llama_memory_t mem = llama_get_memory(ctx); mem != nullptr) {
        llama_memory_clear(mem, true);
    }

    const int32_t n_ctx     = session->n_ctx;
    const int32_t n_batch   = session->n_batch;
    const int32_t n_predict = session->n_predict;
    const int32_t prompt_room = n_ctx - n_predict;
    const int32_t probe = llama_tokenize(vocab, prompt.c_str(),
                                         static_cast<int32_t>(prompt.size()),
                                         nullptr, 0, true, true);
    std::vector<llama_token> tokens;
    if (probe < 0) {
        tokens.resize(static_cast<size_t>(-probe));
    }

    int32_t n_tokens = 0;
    if (!tokens.empty()) {
        n_tokens = llama_tokenize(vocab, prompt.c_str(),
                                  static_cast<int32_t>(prompt.size()),
                                  tokens.data(), static_cast<int32_t>(tokens.size()),
                                  true, true);
    }

    CT_LOGI("worker tokenized n_tokens=%{public}d prompt_room=%{public}d n_predict=%{public}d",
            n_tokens, prompt_room, n_predict);

    if (n_tokens > prompt_room) {
        tokens.erase(tokens.begin(), tokens.begin() + (n_tokens - prompt_room));
        n_tokens = prompt_room;
        CT_LOGW("worker prompt truncated to %{public}d tokens", prompt_room);
    }

    if (n_tokens > 0) {
        ok = true;
        for (int32_t i = 0; i < n_tokens && !session->canceling.load(); i += n_batch) {
            const int32_t n = std::min(n_batch, n_tokens - i);
            llama_batch batch = llama_batch_get_one(tokens.data() + i, n);
            if (llama_decode(ctx, batch) != 0) {
                ok = false;
                break;
            }
        }
    }

    // 默认贪心（与改造前逐位一致）；temperature>0 才走采样链
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(BuildSampler(*session),
                                                                         &llama_sampler_free);
    if (!sampler) {
        CT_LOGE("worker: 采样器创建失败");
        failed = true;
    } else {
        CT_LOGI("worker sampler temperature=%{public}f top_p=%{public}f top_k=%{public}d min_p=%{public}f",
                static_cast<double>(session->temperature), static_cast<double>(session->top_p),
                session->top_k, static_cast<double>(session->min_p));
    }

    for (int32_t step = 0; ok && !failed && step < n_predict && !session->canceling.load(); ++step) {
        llama_token best = llama_sampler_sample(sampler.get(), ctx, -1);
        if (llama_vocab_is_eog(vocab, best)) {
            break;
        }
        llama_sampler_accept(sampler.get(), best);

        char piece[512];
        const int32_t n_piece = llama_token_to_piece(vocab, best, piece,
                                                     static_cast<int32_t>(sizeof(piece)), 0, false);
        if (n_piece > 0) {
            accumulated.append(piece, static_cast<size_t>(n_piece));
            StreamPayload * token_msg = new StreamPayload{kPayloadToken, 0, accumulated};
            const napi_status pst =
                napi_call_threadsafe_function(tsfn, token_msg, napi_tsfn_nonblocking);
            if (pst != napi_ok) {
                CT_LOGE("worker post token FAILED status=%{public}d chars=%{public}zu",
                        static_cast<int>(pst), accumulated.size());
                delete token_msg;
            }
        }

        llama_token next_token = best;
        llama_batch next = llama_batch_get_one(&next_token, 1);
        if (llama_decode(ctx, next) != 0) {
            failed = true;
            break;
        }
    }

    int32_t exit_code = kExitOk;
    if (session->canceling.load()) {
        exit_code = kExitCanceled;
    } else if (!ok || failed) {
        exit_code = kExitError;
    }

    CT_LOGI("worker finish code=%{public}d out_chars=%{public}zu", exit_code, accumulated.size());

    // done 必须在本线程释放 TSFN 之前入队：blocking 语义保证它排在各 token 之后
    StreamPayload * done_msg = new StreamPayload{kPayloadDone, exit_code, accumulated};
    const napi_status dst = napi_call_threadsafe_function(tsfn, done_msg, napi_tsfn_blocking);
    if (dst != napi_ok) {
        CT_LOGE("worker post done FAILED status=%{public}d code=%{public}d", static_cast<int>(dst),
                exit_code);
        delete done_msg;
    }
    CT_LOGI("worker done posted status=%{public}d -> releasing tsfn", static_cast<int>(dst));
    napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    session->busy.store(false);
}

// ---- 5 个导出函数 ----

napi_value CreateContext(napi_env env, napi_callback_info /*info*/) {
    EnsureBackend();
    int64_t handle = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        handle = g_next_handle++;
        g_sessions[handle] = std::make_shared<Session>();
    }
    CT_LOGI("createContext -> handle=%{public}lld sessions=%{public}zu",
            static_cast<long long>(handle), g_sessions.size());
    napi_value result = nullptr;
    const napi_status st = napi_create_double(env, static_cast<double>(handle), &result);
    if (st != napi_ok || result == nullptr) {
        ThrowNapi(env, "createContext", "napi_create_double", st);
        return OkValue(env);
    }
    return result;
}

napi_value LoadModel(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    const napi_status cb_status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (cb_status != napi_ok) {
        ThrowNapi(env, "loadModel", "napi_get_cb_info", cb_status);
        return OkValue(env);
    }
    if (!RequireArgc(env, argc, 2, "loadModel")) {
        return OkValue(env);
    }

    int64_t handle = 0;
    if (!ArgHandle(env, args[0], "loadModel", &handle)) {
        return OkValue(env);
    }
    std::shared_ptr<Session> session = RequireSession(env, handle, "loadModel");
    if (session == nullptr) {
        return OkValue(env);
    }
    std::string path;
    if (!ArgString(env, args[1], "loadModel", "path", &path)) {
        return OkValue(env);
    }
    if (path.empty()) {
        ThrowError(env, "ERR_ARG_EMPTY", "loadModel: 模型路径为空");
        return OkValue(env);
    }
    CT_LOGI("loadModel start handle=%{public}lld path=%{public}s",
            static_cast<long long>(handle), path.c_str());

    // 第 3 个参数 options 可选：{nCtx, nBatch, nPredict, nThreads}
    if (argc >= 3) {
        napi_valuetype opt_type = napi_undefined;
        const napi_status tst = napi_typeof(env, args[2], &opt_type);
        if (tst != napi_ok) {
            ThrowNapi(env, "loadModel", "napi_typeof(options)", tst);
            return OkValue(env);
        }
        if (opt_type == napi_object) {
            int32_t n_ctx     = session->n_ctx;
            int32_t n_batch   = session->n_batch;
            int32_t n_predict = session->n_predict;
            int32_t n_threads = session->n_threads;
            if (!ReadIntOption(env, args[2], "nCtx", "loadModel", 128, 32768, &n_ctx) ||
                !ReadIntOption(env, args[2], "nBatch", "loadModel", 32, 2048, &n_batch) ||
                !ReadIntOption(env, args[2], "nPredict", "loadModel", 1, 8192, &n_predict) ||
                !ReadIntOption(env, args[2], "nThreads", "loadModel", 1, 16, &n_threads)) {
                return OkValue(env);
            }
            if (n_predict >= n_ctx) {
                char msg[160];
                snprintf(msg, sizeof(msg), "loadModel: nPredict(%d) 必须小于 nCtx(%d)", n_predict, n_ctx);
                ThrowError(env, "ERR_INVALID_ARG_VALUE", msg);
                return OkValue(env);
            }

            float temperature = session->temperature;
            float top_p       = session->top_p;
            float min_p       = session->min_p;
            int32_t top_k     = session->top_k;
            int32_t seed      = static_cast<int32_t>(session->seed);
            if (!ReadFloatOption(env, args[2], "temperature", "loadModel", 0.0, 2.0, &temperature) ||
                !ReadFloatOption(env, args[2], "topP", "loadModel", 0.0, 1.0, &top_p) ||
                !ReadFloatOption(env, args[2], "minP", "loadModel", 0.0, 1.0, &min_p) ||
                !ReadIntOption(env, args[2], "topK", "loadModel", 0, 128, &top_k) ||
                !ReadIntOption(env, args[2], "seed", "loadModel", 0, 1000000, &seed)) {
                return OkValue(env);
            }

            session->n_ctx       = n_ctx;
            session->n_batch     = n_batch;
            session->n_predict   = n_predict;
            session->n_threads   = n_threads;
            session->temperature = temperature;
            session->top_p       = top_p;
            session->min_p       = min_p;
            session->top_k       = top_k;
            session->seed        = static_cast<uint32_t>(seed);
        } else if (opt_type != napi_undefined && opt_type != napi_null) {
            ThrowType(env, "loadModel", "options（必须是对象）");
            return OkValue(env);
        }
    }

    // 重载模型：先停掉正在跑的 worker，再换 ctx/model（全程持 session 锁）
    std::lock_guard<std::mutex> session_lock(session->mu);
    session->canceling.store(true);
    if (session->worker.joinable()) {
        session->worker.join();
    }
    session->canceling.store(false);
    session->busy.store(false);

    if (session->ctx != nullptr) {
        llama_free(session->ctx);
        session->ctx = nullptr;
    }
    if (session->model != nullptr) {
        llama_model_free(session->model);
        session->model = nullptr;
    }
    session->vocab = nullptr;

    EnsureBackend();

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0; // 没有 GPU 后端，纯 CPU

    session->model = llama_model_load_from_file(path.c_str(), model_params);
    if (session->model == nullptr) {
        char msg[512];
        snprintf(msg, sizeof(msg), "loadModel: 模型文件加载失败（路径不存在、不是 gguf 或文件损坏）：%s",
                 path.c_str());
        ThrowError(env, "ERR_MODEL_LOAD_FAILED", msg);
        return OkValue(env);
    }

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx           = static_cast<uint32_t>(session->n_ctx);
    ctx_params.n_batch         = static_cast<uint32_t>(session->n_batch);
    ctx_params.n_ubatch        = static_cast<uint32_t>(session->n_batch);
    const unsigned hw_threads  = std::thread::hardware_concurrency();
    const int32_t  threads     = session->n_threads > 0
                                     ? session->n_threads
                                     : static_cast<int32_t>(hw_threads == 0 ? 4u : std::min(hw_threads, 6u));
    ctx_params.n_threads       = threads;
    ctx_params.n_threads_batch = threads;

    session->ctx = llama_init_from_model(session->model, ctx_params);
    if (session->ctx == nullptr) {
        char msg[256];
        snprintf(msg, sizeof(msg), "loadModel: 创建推理上下文失败（n_ctx=%d），内存不足或参数不合法",
                 session->n_ctx);
        ThrowError(env, "ERR_CTX_INIT_FAILED", msg);
        llama_model_free(session->model);
        session->model = nullptr;
        return OkValue(env);
    }

    session->vocab = llama_model_get_vocab(session->model);
    if (session->vocab == nullptr) {
        ThrowError(env, "ERR_NO_VOCAB", "loadModel: 模型没有可用的 vocab");
        return OkValue(env);
    }
    CT_LOGI("loadModel ok handle=%{public}lld n_ctx=%{public}d n_batch=%{public}d n_predict=%{public}d "
            "threads=%{public}d",
            static_cast<long long>(handle), session->n_ctx, session->n_batch, session->n_predict, threads);
    return MakeBoolean(env, true);
}

napi_value GenerateStream(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    const napi_status cb_status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (cb_status != napi_ok) {
        ThrowNapi(env, "generateStream", "napi_get_cb_info", cb_status);
        return OkValue(env);
    }
    if (!RequireArgc(env, argc, 3, "generateStream")) {
        return OkValue(env);
    }

    int64_t handle = 0;
    if (!ArgHandle(env, args[0], "generateStream", &handle)) {
        return OkValue(env);
    }
    std::shared_ptr<Session> session = RequireSession(env, handle, "generateStream");
    if (session == nullptr) {
        return OkValue(env);
    }
    if (session->ctx == nullptr || session->vocab == nullptr) {
        char msg[192];
        snprintf(msg, sizeof(msg), "generateStream: handle=%lld 尚未 loadModel", static_cast<long long>(handle));
        ThrowError(env, "ERR_NOT_LOADED", msg);
        return OkValue(env);
    }

    napi_valuetype cb_type = napi_undefined;
    const napi_status type_status = napi_typeof(env, args[2], &cb_type);
    if (type_status != napi_ok) {
        ThrowNapi(env, "generateStream", "napi_typeof(onToken)", type_status);
        return OkValue(env);
    }
    if (cb_type != napi_function) {
        ThrowType(env, "generateStream", "onToken（必须是 function）");
        return OkValue(env);
    }

    std::string prompt;
    if (!ArgString(env, args[1], "generateStream", "prompt", &prompt)) {
        return OkValue(env);
    }
    if (prompt.empty()) {
        ThrowError(env, "ERR_ARG_EMPTY", "generateStream: prompt 为空");
        return OkValue(env);
    }

    if (session->busy.load()) {
        char msg[192];
        snprintf(msg, sizeof(msg), "generateStream: handle=%lld 正在生成中，先 cancel 再调用",
                 static_cast<long long>(handle));
        ThrowError(env, "ERR_BUSY", msg);
        return OkValue(env);
    }
    // 与 LoadModel/ReleaseContext 用同一把 session 锁，避免并发改 std::thread 对象
    std::lock_guard<std::mutex> session_lock(session->mu);
    // 上一轮线程已经退出但 std::thread 对象还没回收，join 会立刻返回
    if (session->worker.joinable()) {
        session->worker.join();
    }
    session->canceling.store(false);

    StreamCtx * stream_ctx = new StreamCtx();
    napi_valuetype done_type = napi_undefined;
    if (argc >= 4) {
        napi_typeof(env, args[3], &done_type);
    }
    if (done_type == napi_function) {
        if (napi_create_reference(env, args[3], 1, &stream_ctx->done_ref) != napi_ok) {
            stream_ctx->done_ref = nullptr;
        }
    }

    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "llamaohos.generateStream", NAPI_AUTO_LENGTH, &resource_name);

    napi_threadsafe_function tsfn = nullptr;
    const napi_status status = napi_create_threadsafe_function(
        env, args[2], nullptr, resource_name,
        0, 1, stream_ctx, FinalizeStreamCtx, stream_ctx, CallJs, &tsfn);
    if (status != napi_ok || tsfn == nullptr) {
        if (stream_ctx->done_ref != nullptr) {
            napi_delete_reference(env, stream_ctx->done_ref);
        }
        delete stream_ctx;
        ThrowNapi(env, "generateStream", "napi_create_threadsafe_function", status);
        return OkValue(env);
    }

    // 回调会把 handle 与 done 信号交给 ArkTS，参数名与 d.ts 保持一致
    CT_LOGI("generateStream handle=%{public}lld has_done_cb=%{public}d",
            static_cast<long long>(handle), stream_ctx->done_ref != nullptr ? 1 : 0);
    session->busy.store(true);
    session->worker = std::thread(GenerationWorker, session, std::move(prompt), tsfn);
    return OkValue(env);
}

napi_value Cancel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    const napi_status cb_status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (cb_status != napi_ok) {
        ThrowNapi(env, "cancel", "napi_get_cb_info", cb_status);
        return OkValue(env);
    }
    if (!RequireArgc(env, argc, 1, "cancel")) {
        return OkValue(env);
    }
    int64_t handle = 0;
    if (!ArgHandle(env, args[0], "cancel", &handle)) {
        return OkValue(env);
    }
    std::shared_ptr<Session> session = RequireSession(env, handle, "cancel");
    if (session == nullptr) {
        return OkValue(env);
    }
    session->canceling.store(true);
    CT_LOGI("cancel handle=%{public}lld busy=%{public}d", static_cast<long long>(handle),
            session->busy.load() ? 1 : 0);
    return OkValue(env);
}

napi_value ReleaseContext(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    const napi_status cb_status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (cb_status != napi_ok) {
        ThrowNapi(env, "releaseContext", "napi_get_cb_info", cb_status);
        return OkValue(env);
    }
    if (!RequireArgc(env, argc, 1, "releaseContext")) {
        return OkValue(env);
    }
    int64_t handle = 0;
    if (!ArgHandle(env, args[0], "releaseContext", &handle)) {
        return OkValue(env);
    }

    std::shared_ptr<Session> owned;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_sessions.find(handle);
        if (it != g_sessions.end()) {
            owned = std::move(it->second);
            g_sessions.erase(it);
        }
    }
    if (!owned) {
        // 已经释放过：幂等返回 false，不抛异常、不崩
        CT_LOGW("releaseContext: handle=%{public}lld 已释放或无此句柄", static_cast<long long>(handle));
        return MakeBoolean(env, false);
    }
    CT_LOGI("releaseContext handle=%{public}lld sessions=%{public}zu",
            static_cast<long long>(handle), g_sessions.size());

    // 先标记取消并 join，worker 退出后没人再碰 ctx/model，才可以安全释放
    std::lock_guard<std::mutex> session_lock(owned->mu);
    owned->canceling.store(true);
    if (owned->worker.joinable()) {
        owned->worker.join();
    }
    owned->busy.store(false);
    if (owned->ctx != nullptr) {
        llama_free(owned->ctx);
    }
    if (owned->model != nullptr) {
        llama_model_free(owned->model);
    }
    return MakeBoolean(env, true);
}

// 把当前推理参数回读给 ArkTS，方便界面展示与自检
napi_value GetParams(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    const napi_status cb_status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (cb_status != napi_ok) {
        ThrowNapi(env, "getParams", "napi_get_cb_info", cb_status);
        return OkValue(env);
    }
    if (!RequireArgc(env, argc, 1, "getParams")) {
        return OkValue(env);
    }
    int64_t handle = 0;
    if (!ArgHandle(env, args[0], "getParams", &handle)) {
        return OkValue(env);
    }
    std::shared_ptr<Session> session = RequireSession(env, handle, "getParams");
    if (session == nullptr) {
        return OkValue(env);
    }

    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
        ThrowError(env, "ERR_NAPI", "getParams: napi_create_object 失败");
        return OkValue(env);
    }
    const struct {
        const char * key;
        int32_t      value;
    } int_fields[] = {
        {"nCtx", session->n_ctx},
        {"nBatch", session->n_batch},
        {"nPredict", session->n_predict},
        {"nThreads", session->n_threads},
        {"topK", session->top_k},
        {"seed", static_cast<int32_t>(session->seed)},
    };
    for (const auto & field : int_fields) {
        napi_value number = nullptr;
        if (napi_create_int32(env, field.value, &number) != napi_ok ||
            napi_set_named_property(env, result, field.key, number) != napi_ok) {
            ThrowNapi(env, "getParams", "napi_set_named_property(int)", napi_generic_failure);
            return OkValue(env);
        }
    }
    const struct {
        const char * key;
        float        value;
    } float_fields[] = {
        {"temperature", session->temperature},
        {"topP", session->top_p},
        {"minP", session->min_p},
    };
    for (const auto & field : float_fields) {
        napi_value number = nullptr;
        if (napi_create_double(env, static_cast<double>(field.value), &number) != napi_ok ||
            napi_set_named_property(env, result, field.key, number) != napi_ok) {
            ThrowNapi(env, "getParams", "napi_set_named_property(float)", napi_generic_failure);
            return OkValue(env);
        }
    }
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"createContext",  nullptr, CreateContext,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModel",      nullptr, LoadModel,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generateStream", nullptr, GenerateStream, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel",         nullptr, Cancel,         nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseContext", nullptr, ReleaseContext, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getParams",      nullptr, GetParams,      nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    const size_t count = sizeof(desc) / sizeof(desc[0]);
    const napi_status st = napi_define_properties(env, exports, count, desc);
    if (st != napi_ok) {
        ThrowNapi(env, "init", "napi_define_properties(exports)", st);
        return exports;
    }

    napi_value namespace_obj = nullptr;
    if (napi_create_object(env, &namespace_obj) != napi_ok) {
        ThrowNapi(env, "init", "napi_create_object(LlamaNative)", napi_generic_failure);
        return exports;
    }
    const napi_status st2 = napi_define_properties(env, namespace_obj, count, desc);
    if (st2 != napi_ok) {
        ThrowNapi(env, "init", "napi_define_properties(LlamaNative)", st2);
        return exports;
    }
    const napi_status st3 = napi_set_named_property(env, exports, "LlamaNative", namespace_obj);
    if (st3 != napi_ok) {
        ThrowNapi(env, "init", "napi_set_named_property(LlamaNative)", st3);
    }
    return exports;
}

} // namespace

static napi_module g_llamaohos_module = {
    1,            // nm_version
    0,            // nm_flags
    nullptr,      // nm_filename
    Init,         // nm_register_func
    "llamaohos",  // nm_modname
    nullptr,      // nm_priv
    {0},          // reserved
};

extern "C" __attribute__((constructor)) void RegisterLlamaOhosModule(void) {
    napi_module_register(&g_llamaohos_module);
}


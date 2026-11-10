import Foundation
import COlicoFFI

public struct CoreError: Error, LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public final class CoreClient {
    private let handle: OpaquePointer
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(dataDir: URL) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let handle = olico_core_new(dataDir.path) else {
            throw CoreError(code: "init_failed", message: "无法打开数据目录 \(dataDir.path)")
        }
        self.handle = handle
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    deinit {
        olico_core_free(handle)
    }

    public func raw(_ request: String) -> String {
        guard let ptr = olico_dispatch(handle, request) else {
            return #"{"v":1,"ok":false,"error":{"code":"ffi_error","message":"dispatch returned null"}}"#
        }
        defer { olico_string_free(ptr) }
        return String(cString: ptr)
    }

    public func call(_ op: String, payload: [String: Any] = [:]) throws -> Any {
        let request: [String: Any] = ["v": 1, "op": op, "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let responseData = Data(raw(body).utf8)
        let envelope = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard (envelope["ok"] as? Bool) == true else {
            let error = envelope["error"] as? [String: Any] ?? [:]
            throw CoreError(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? "未知错误"
            )
        }
        return envelope["data"] ?? [:]
    }

    public func call<T: Decodable>(_ op: String, payload: [String: Any] = [:], as type: T.Type) throws -> T {
        let value = try call(op, payload: payload)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: data)
    }

    public func config() throws -> AppConfig {
        try call("config_get", as: AppConfig.self)
    }

    public func setConfig(_ config: AppConfig) throws {
        let data = try encoder.encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        _ = try call("config_set", payload: ["config": object])
    }

    public func clipboardClear() throws {
        _ = try call("clipboard_clear")
    }

    public func clipboardDelete(id: String) throws {
        _ = try call("clipboard_delete", payload: ["id": id])
    }

    public func clipboardPin(id: String, pinned: Bool) throws {
        _ = try call("clipboard_pin", payload: ["id": id, "pinned": pinned])
    }

    public func pinboards() throws -> [Pinboard] {
        try call("pinboard_list", as: [Pinboard].self)
    }
}

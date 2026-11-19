import ScribeAppCore

extension WorkerEnvelope {
    static func error(
        requestID: String,
        code: String,
        message: String,
        details: WorkerJSONValue = .object([:]),
        version: Int = WorkerEnvelope.currentVersion
    ) -> WorkerEnvelope {
        WorkerEnvelope(version: version, kind: .error, requestID: requestID, payload: .object([
            "code": .string(code),
            "message": .string(message),
            "details": details,
        ]))
    }
}

extension WorkerWireFormatError {
    var workerDiagnostic: String {
        switch self {
        case let .messageTooLarge(actualBytes, limitBytes):
            "Message is \(actualBytes) bytes; the protocol limit is \(limitBytes) bytes. Stream large results to disk."
        case let .unsupportedVersion(version):
            "Unsupported protocol version \(version)."
        case let .malformedMessage(reason):
            "Malformed JSON message: \(reason)"
        }
    }
}

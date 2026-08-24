import Foundation

@objc(FennecHelperProtocol) protocol FennecHelperProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func restartCoreAudio(withReply reply: @escaping (Bool, String) -> Void)
}

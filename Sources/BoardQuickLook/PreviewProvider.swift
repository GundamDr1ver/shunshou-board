import QuickLookUI

@objc(BoardPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        do { handler(QLPreviewReply(fileURL:try projectPreviewURL(request.fileURL)),nil) }
        catch { handler(nil,error) }
    }
}

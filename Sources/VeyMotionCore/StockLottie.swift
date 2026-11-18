import Foundation

/// Lottie animations from LottieFiles (lottiefiles.com), through its public GraphQL API (no key). Free animations
/// there are under the Lottie Simple License: commercial use and changes allowed, credit encouraged but not
/// required; it does not allow compiling its files into a competing collection, so results are fetched one search
/// at a time and only the chosen ones are downloaded. Results are imported as .json (a .lottie would be unzipped
/// into the system temp folder, which sandboxed processes cannot use) and play in a video layer (`LottieSource`).
enum LottieStock {
    static let refPrefix = "lottiefiles"
    static let pageSize = 20
    private static let endpoint = URL(string: "https://graphql.lottiefiles.com/2022-08")!
    private static let fields = """
    id name url jsonUrl imageUrl lottieFileSize metadata { width height duration layers } \
    createdBy { firstName lastName username }
    """

    static func search(_ q: String, page: Int) throws -> [StockItem] {
        // Relay cursors are base64 "arrayconnection:<index of the last result before the page>".
        let after = page > 1 ? Data("arrayconnection:\((page - 1) * pageSize - 1)".utf8).base64EncodedString() : nil
        let data = try call("""
        query($q: String!, $first: Int, $after: String) { searchPublicAnimations(query: $q, first: $first, after: $after) \
        { edges { node { \(fields) } } } }
        """, variables: ["q": q, "first": pageSize, "after": after.map { $0 as Any } ?? NSNull()])
        let edges = (data["searchPublicAnimations"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        return edges.compactMap { ($0["node"] as? [String: Any]).flatMap(item) }
    }

    static func item(id: String) throws -> StockItem {
        guard let n = Int(id) else { throw AssetError.failed("Bad LottieFiles id \(id)") }
        let data = try call("query($id: Int!) { publicAnimation(id: $id) { \(fields) } }", variables: ["id": n])
        guard let node = data["publicAnimation"] as? [String: Any], let item = item(node) else {
            throw AssetError.failed("LottieFiles has no animation \(id)")
        }
        return item
    }

    static func item(_ n: [String: Any]) -> StockItem? {
        guard let id = (n["id"] as? NSNumber)?.intValue, let json = (n["jsonUrl"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        let title = (n["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Animation \(id)"
        let by = n["createdBy"] as? [String: Any]
        let creator = [by?["firstName"] as? String, by?["lastName"] as? String].compactMap { $0 }.joined(separator: " ")
        let ref = "\(refPrefix):\(id)"
        let credit = AssetCredit(title: title, creator: creator.isEmpty ? nil : creator, license: "Lottie Simple License",
                                 licenseURL: "https://lottiefiles.com/page/license", sourceURL: n["url"] as? String,
                                 attribution: "Animation \"\(title)\"\(creator.isEmpty ? "" : " by \(creator)") from LottieFiles.",
                                 requiresAttribution: false, ref: ref)
        var item = StockItem(ref: ref, kind: .animation, title: title,
                             thumbnailURL: (n["imageUrl"] as? String).flatMap(URL.init(string:)),
                             fileExtension: "json", credit: credit)
        item.downloadURL = json
        item.source = "LottieFiles"
        let meta = n["metadata"] as? [String: Any]
        if let w = (meta?["width"] as? NSNumber)?.doubleValue, let h = (meta?["height"] as? NSNumber)?.doubleValue {
            item.width = Int(w.rounded()); item.height = Int(h.rounded())
        }
        item.duration = (meta?["duration"] as? NSNumber)?.doubleValue
        // A few layers in a big file is usually a bitmap wrapped in a Lottie, not vector art.
        if let layers = (meta?["layers"] as? NSNumber)?.intValue { item.tags.append("\(layers) layer\(layers == 1 ? "" : "s")") }
        if let bytes = (n["lottieFileSize"] as? NSNumber)?.intValue { item.tags.append("\(max(1, bytes / 1024)) KB") }
        return item
    }

    private static func call(_ query: String, variables: [String: Any]) throws -> [String: Any] {
        var req = HTTP.request(endpoint, timeout: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (body, response) = try HTTP.perform(req)
        if let status = response?.statusCode, !(200..<300).contains(status) {
            throw AssetError.failed(status == 429 ? "LottieFiles is rate-limiting requests. Wait a minute and try again."
                                                  : "LottieFiles returned HTTP \(status)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AssetError.failed("Unexpected response from LottieFiles")
        }
        if let errors = obj["errors"] as? [[String: Any]], let first = errors.first?["message"] as? String {
            throw AssetError.failed("LottieFiles: \(first)")
        }
        return obj["data"] as? [String: Any] ?? [:]
    }
}

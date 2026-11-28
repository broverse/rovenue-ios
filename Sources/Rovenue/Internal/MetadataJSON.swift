import Foundation

/// Parses a core `metadata_json` string. The core already guarantees an object
/// (spec D4); anything else still yields `[:]` rather than a crash in a paywall.
func parseMetadataJSON(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

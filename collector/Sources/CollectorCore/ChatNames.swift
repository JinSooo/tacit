import Foundation

/// 聊天名的采集规则与比较键；不改写已入库记录。
public enum ChatNames {
  public static func key(_ name: String) -> String {
    name.components(separatedBy: .whitespacesAndNewlines).joined()
  }

  public static func normalize(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return words.reduce("") { result, word in
      guard let last = result.unicodeScalars.last, let first = word.unicodeScalars.first else { return word }
      let joins = (isCJK(last) && CharacterSet.alphanumerics.contains(first))
        || (isCJK(first) && CharacterSet.alphanumerics.contains(last))
      return result + (joins ? "" : " ") + word
    }
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
    default: return false
    }
  }

  public static func isFilePreview(_ title: String) -> Bool {
    let extensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "zip", "rar", "7z", "gz", "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "mp4", "mov", "avi", "mkv", "mp3", "wav", "csv", "rtf", "pages", "numbers", "key"]
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return extensions.contains((trimmed as NSString).pathExtension.lowercased())
  }

  public static func isValid(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.unicodeScalars.first else { return false }
    if "←→↑↓↔↕↖↗↘↙‹›<>〈〉《》❮❯❬❭⟨⟩＜＞⬅➡◀▶◁▷⏴⏵".unicodeScalars.contains(first)
      || (0x2190...0x21FF).contains(first.value) { return false }
    return !isFilePreview(trimmed) && trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || isCJK($0) }
  }
}

import Foundation
import Security
import CryptoKit

/// Чем разрешено подписывать обновления.
///
/// Проверка опирается на сертификат, которым подписано **уже установленное** приложение:
/// обновление принимается, только если его листовой сертификат совпадает с нашим (или входит
/// в список на время смены сертификата). Так компрометация GitHub-аккаунта или релизного
/// токена не даёт выполнить код: чужой архив будет подписан другим сертификатом.
///
/// Пока сборки подписываются ad-hoc (сертификата нет), привязывать нечего — проверка остаётся
/// прежней: целостность подписи и SHA256 архива. Как только сборка подписана постоянным
/// сертификатом, привязка включается сама, без отдельного списка отпечатков в коде.
public enum SigningIdentity {
    /// Дополнительные отпечатки листовых сертификатов — только на время смены сертификата.
    /// В переходной версии остаются старый и новый, после чего старый убирается.
    public static let extraLeafHashes: [String] = []

    /// SHA-1 отпечатки листового сертификата подписи бандла; пусто — подпись ad-hoc.
    public static func leafHashes(of bundle: URL) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return [] }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] else {
            return []
        }
        // Листовой сертификат идёт первым, дальше — промежуточные и корневой.
        return certificates.prefix(1).map { certificate in
            let der = SecCertificateCopyData(certificate) as Data
            return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
        }
    }

    /// Требование codesign вида `certificate leaf = H"…"`; `nil` — привязки нет.
    public static func requirement(for hashes: [String]) -> String? {
        let unique = hashes.map { $0.uppercased() }.filter { !$0.isEmpty }
        guard !unique.isEmpty else { return nil }
        return unique.map { #"certificate leaf = H"\#($0)""# }.joined(separator: " or ")
    }

    public static func accepts(_ leafHash: String, among hashes: [String]) -> Bool {
        hashes.contains { $0.caseInsensitiveCompare(leafHash) == .orderedSame }
    }
}

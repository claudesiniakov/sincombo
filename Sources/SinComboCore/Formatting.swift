import Foundation

/// Объём трафика: МБ и ГБ — с одной цифрой после запятой («1,4 ГБ»), КБ — целые («810 КБ»),
/// меньше килобайта — байты. Единица выбирается по уже округлённому значению: 999 999 байт —
/// это «1,0 МБ», а не «1000 КБ».
public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        guard b >= 1_000 else { return String(Int(b.rounded())) + " Б" }
        let gb = rounded(b / 1e9)
        if gb >= 1 { return number(gb) + " ГБ" }
        let mb = rounded(b / 1e6)
        if mb >= 1 { return number(mb) + " МБ" }
        let kb = (b / 1e3).rounded()
        if kb >= 1_000 { return number(rounded(kb / 1e3)) + " МБ" }
        return String(Int(kb)) + " КБ"
    }

    /// Округление до десятых: по нему видно, что 999 999 байт — уже мегабайт.
    static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func number(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

public enum DurationFormat {
    /// «чч:мм:сс» — для текущей сессии.
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// «1 ч 25 мин» / «25 мин» / «2 ч» — для итогов за день и за 30 дней.
    public static func short(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = s % 3600 / 60
        guard h > 0 else { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }
}

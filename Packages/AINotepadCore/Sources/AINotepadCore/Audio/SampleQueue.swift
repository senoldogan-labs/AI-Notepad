/// Önden tüketilen ses örneği kuyruğu. Dizinin başından silmek her seferinde kalan diziyi kaydırır: uzun kesintiden
/// sonra (ör. 30 dakikalık telefon görüşmesi) biriken ~29 milyon örneğin yarım saniyelik parçalarla gönderimi
/// O(n²) bellek kaydırması (yüzlerce GB) demekti. Burada baştan alma alınan parça kadardır; tüketilen baş, dizinin
/// yarısını geçince bir kez atılır (toplamda doğrusal).
struct SampleQueue: Sendable, Equatable {
    private var storage: [Float] = []
    private var head: Int = 0

    /// Kuyruktaki örnek sayısı.
    var count: Int {
        storage.count - head
    }

    var isEmpty: Bool {
        count == 0
    }

    /// Sona ekler.
    mutating func append(contentsOf samples: [Float]) {
        storage.append(contentsOf: samples)
    }

    /// Başa ekler (yeniden gönderilecek ses; seyrek: bağlantı koptuğunda).
    mutating func prepend(_ samples: [Float]) {
        storage = samples + storage[head...]
        head = 0
    }

    /// Baştan en çok `maxCount` örnek alır.
    mutating func popFront(maxCount: Int) -> [Float] {
        let end: Int = min(head + max(0, maxCount), storage.count)
        let taken: [Float] = Array(storage[head..<end])
        head = end
        if head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return taken
    }

    /// Kuyruğun tamamı (sırayla).
    var samples: [Float] {
        Array(storage[head...])
    }
}

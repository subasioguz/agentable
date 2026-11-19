import Foundation
import AgentableCore

/// A small shop database for screenshots and manual testing: customers, orders, payments and
/// friends, with the same values as the design so screens can be compared side by side.
///
///     AgentableApp --seed-demo /tmp/acme.sqlite
///     AgentableApp --seed-demo 'postgres://agentable@localhost:55432/postgres?sslmode=disable'
///
/// Existing demo tables are dropped and recreated.
enum DemoData {
    static func seedFromCommandLine(_ target: String) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ExitBox()
        Task.detached {
            do {
                let rows = try await seed(target)
                print("Seeded \(rows) rows into \(target)")
            } catch {
                FileHandle.standardError.write(Data("Seeding failed: \(error)\n".utf8))
                box.code = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.code
    }

    final class ExitBox: @unchecked Sendable {
        var code: Int32 = 0
    }

    static func seed(_ target: String) async throws -> Int {
        let parsed = try ConnectionURL.parse(target, name: "demo", environment: .local)
        let session: any DatabaseSession
        switch parsed.profile.engine {
        case .sqlite:
            session = try SQLiteSession(path: parsed.profile.database ?? target, mode: .create)
        case .postgres:
            session = try await PostgresSession.connect(profile: parsed.profile, password: parsed.password, readOnly: false)
        }
        do {
            let statements = build(dialect: parsed.profile.engine.sqlDialect)
            _ = try await session.apply(statements.map { BoundSQL($0) }, timeout: .seconds(120))
            await session.close()
            return statements.count
        } catch {
            await session.close()
            throw error
        }
    }

    // MARK: Data

    private struct Generator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }

        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

        mutating func chance(_ percent: Int) -> Bool { int(1...100) <= percent }
    }

    private static let firstNames = ["Mara", "Kenji", "Ayşe", "Tomás", "Priya", "Jonas", "Daniel", "Elif", "Noah", "Chloé", "Lucas", "Hana", "Oliver",
                                     "Sofia", "Mateo", "Amara", "Yuki", "Liam", "Zeynep", "Arjun", "Ingrid", "Diego", "Fatima", "Emre", "Lea",
                                     "Ravi", "Nora", "Kofi", "Mei", "Isak", "Valentina", "Omar", "Can", "Ana", "Felix", "Leila", "Hugo", "Selin"]
    private static let lastNames = ["Lindqvist", "Watanabe", "Demir", "Herrera", "Raman", "Weber", "Okafor", "Kaya", "Fischer", "Martin", "Silva",
                                    "Kim", "Brown", "Rossi", "García", "Nwosu", "Tanaka", "Murphy", "Yılmaz", "Mehta", "Berg", "López",
                                    "Haddad", "Şahin", "Dubois", "Patel", "Novak", "Mensah", "Chen", "Nilsson", "Costa", "Farouk", "Aydın"]
    private static let companies = ["Orbit Freight", "Northwind Labs", "Mosaic Learning", "Halcyon Foods", "Kestrel Health", "Bluepine Studio",
                                    "Tidewater Co.", "Lumen Dental", "Fjord Analytics", "Cedar & Pine", "Quarry Works", "Atlas Bikes"]

    /// The first orders on screen, as in the design.
    private static let featured: [(id: Int, first: String, last: String, status: String, total: String, currency: String, channel: String, minutesAgo: Int)] = [
        (84213, "Mara", "Lindqvist", "pending", "129.00", "EUR", "web", 18),
        (84212, "Kenji", "Watanabe", "paid", "64.50", "USD", "ios", 23),
        (84211, "Ayşe", "Demir", "shipped", "312.90", "TRY", "web", 39),
        (84210, "Tomás", "Herrera", "shipped", "89.00", "EUR", "web", 62),
        (84209, "Priya", "Raman", "paid", "1204.00", "USD", "web", 80),
        (84208, "Jonas", "Weber", "refunded", "39.90", "EUR", "ios", 108),
        (84207, "Sofia", "Rossi", "delivered", "18.40", "EUR", "web", 150),
        (84206, "Daniel", "Okafor", "shipped", "256.40", "USD", "web", 624),
        (84205, "Elif", "Kaya", "paid", "89.90", "TRY", "ios", 653),
        (84204, "Noah", "Fischer", "shipped", "74.00", "EUR", "web", 730),
        (84203, "Chloé", "Martin", "paid", "142.00", "EUR", "web", 815),
        (84202, "Lucas", "Silva", "paid", "58.20", "USD", "pos", 899),
        (84201, "Hana", "Kim", "shipped", "33.00", "USD", "ios", 988),
        (84200, "Oliver", "Brown", "paid", "410.75", "USD", "web", 1_006),
    ]

    static func build(dialect: SQLDialect) -> [String] {
        let pg = dialect == .postgres
        let cascade = pg ? " CASCADE" : ""
        var sql: [String] = ["refunds", "payments", "shipments", "invoices", "order_items", "orders", "products", "api_keys", "customers"].map {
            "DROP TABLE IF EXISTS \($0)\(cascade)"
        }
        sql += [
            "CREATE TABLE customers (id bigint PRIMARY KEY, name text NOT NULL, company text, email text, phone text, tier text NOT NULL DEFAULT 'standard', country char(2), created_at timestamptz NOT NULL)",
            "CREATE TABLE products (id bigint PRIMARY KEY, name text NOT NULL, sku text NOT NULL, price numeric(10,2) NOT NULL)",
            """
            CREATE TABLE orders (id bigint PRIMARY KEY, customer_id bigint NOT NULL REFERENCES customers(id), \
            status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'shipped', 'delivered', 'refunded', 'refund_pending', 'cancelled')), \
            total numeric(10,2) NOT NULL DEFAULT 0 CHECK (total >= 0), currency char(3) NOT NULL DEFAULT 'EUR', created_at timestamptz NOT NULL, \
            channel text NOT NULL DEFAULT 'web', metadata \(pg ? "jsonb" : "json"))
            """,
            "CREATE TABLE order_items (id bigint PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders(id), product_id bigint NOT NULL REFERENCES products(id), quantity integer NOT NULL, price numeric(10,2) NOT NULL)",
            "CREATE TABLE payments (id bigint PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders(id), status text NOT NULL, amount numeric(10,2) NOT NULL, card_last4 char(4), created_at timestamptz NOT NULL)",
            "CREATE TABLE refunds (id bigint PRIMARY KEY, payment_id bigint NOT NULL REFERENCES payments(id), amount numeric(10,2) NOT NULL, reason text, created_at timestamptz NOT NULL)",
            "CREATE TABLE shipments (id bigint PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders(id), carrier text NOT NULL, tracking text, shipped_at timestamptz)",
            "CREATE TABLE invoices (id bigint PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders(id), number text NOT NULL, total numeric(10,2) NOT NULL, issued_at timestamptz NOT NULL)",
            "CREATE TABLE api_keys (id bigint PRIMARY KEY, customer_id bigint NOT NULL REFERENCES customers(id), token text NOT NULL, created_at timestamptz NOT NULL)",
            "CREATE INDEX orders_customer_id_idx ON orders (customer_id)",
            "CREATE INDEX orders_created_at_idx ON orders (created_at DESC)",
            "CREATE INDEX payments_order_id ON payments (order_id)",
        ]

        var random = Generator()
        let now = Date.now
        func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        func literal(_ text: String?) -> String { text.map { SQLBuilder.literal(.text($0)) } ?? "NULL" }

        // Customers
        var customers: [[String]] = []
        var customerIDs: [String: Int] = [:]
        let customerCount = 2_400
        for index in 0..<customerCount {
            let id = index + 1
            let first = firstNames[index % firstNames.count]
            let last = lastNames[(index / firstNames.count + index) % lastNames.count]
            let name = "\(first) \(last)"
            if customerIDs[name] == nil { customerIDs[name] = id }
            let handle = first.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter)
            let company = random.chance(40) ? random.pick(companies) : nil
            let tier = random.chance(8) ? "vip" : (random.chance(30) ? "pro" : "standard")
            let created = now.addingTimeInterval(-Double(random.int(30...900)) * 86_400)
            customers.append([String(id), literal(name), literal(company), literal("\(handle).\(id)@example.com"),
                              literal("+1 555 \(String(format: "%04d", id % 10_000))"), literal(tier),
                              literal(random.pick(["US", "DE", "TR", "GB", "FR", "BR", "JP", "IN", "SE", "NG"])), literal(stamp(created))])
        }
        sql += batches("customers", customers)

        // Products
        let productNames = ["Trail Jacket", "Merino Socks", "Canvas Tote", "Steel Bottle", "Wool Beanie", "Rain Shell", "Day Pack", "Camp Mug",
                            "Base Layer", "Field Notebook", "Headlamp", "Down Vest", "Hiking Boots", "Sun Hat", "Gaiters", "Dry Bag"]
        let products = productNames.enumerated().map { index, name in
            [String(index + 1), literal(name), literal("SKU-\(1_000 + index)"), String(format: "%.2f", Double(random.int(800...24_000)) / 100)]
        }
        sql += batches("products", products)

        // Orders, newest first, with the featured ones on top. Metadata draws from its own
        // generator so the other values stay as they were before it existed.
        var extra = Generator(state: 0x51ED_2701_A3C4_88B1)
        func metadata(_ id: Int) -> String? {
            if id == 84_209 { return #"{"source": "checkout", "coupon": null, "items": 3, "utm": {"campaign": "autumn", "medium": "email"}}"# }
            guard extra.chance(80) else { return nil }
            var parts = [#""source": "\#(extra.pick(["checkout", "checkout", "app", "pos", "api"]))""#]
            parts.append(#""coupon": "# + (extra.chance(25) ? #""\#(extra.pick(["WELCOME10", "AUTUMN15", "VIP20"]))""# : "null"))
            parts.append(#""items": \#(extra.int(1...4))"#)
            if extra.chance(40) {
                parts.append(#""utm": {"campaign": "\#(extra.pick(["autumn", "black-friday", "newsletter"]))", "medium": "\#(extra.pick(["email", "social", "search"]))"}"#)
            }
            return "{" + parts.joined(separator: ", ") + "}"
        }
        var orders: [[String]] = []
        var orderMeta: [(id: Int, total: String, created: Date, status: String)] = []
        for item in featured {
            let created = now.addingTimeInterval(-Double(item.minutesAgo) * 60)
            let customer = customerIDs["\(item.first) \(item.last)"] ?? 1
            orders.append([String(item.id), String(customer), literal(item.status), item.total, literal(item.currency), literal(stamp(created)), literal(item.channel),
                           literal(metadata(item.id))])
            orderMeta.append((item.id, item.total, created, item.status))
        }
        var minutes = featured.last!.minutesAgo
        for id in stride(from: 84_199, through: 60_200, by: -1) {
            minutes += random.int(3...14)
            let created = now.addingTimeInterval(-Double(minutes) * 60)
            let age = now.timeIntervalSince(created) / 86_400
            let status: String
            if age < 1 { status = random.pick(["pending", "paid", "paid", "shipped"]) }
            else if age < 5 { status = random.pick(["paid", "shipped", "shipped", "delivered"]) }
            else { status = random.chance(4) ? "refunded" : (random.chance(2) ? "cancelled" : "delivered") }
            let total = String(format: "%.2f", Double(random.int(900...60_000)) / 100)
            orders.append([String(id), String(random.int(1...customerCount)), literal(status), total,
                           literal(random.pick(["USD", "USD", "EUR", "EUR", "TRY", "GBP"])), literal(stamp(created)),
                           literal(random.pick(["web", "web", "web", "ios", "ios", "android", "pos"])), literal(metadata(id))])
            orderMeta.append((id, total, created, status))
        }
        sql += batches("orders", orders)

        // Items, payments, shipments, invoices.
        var items: [[String]] = []
        var payments: [[String]] = []
        var shipments: [[String]] = []
        var invoices: [[String]] = []
        var refunds: [[String]] = []
        var paymentID = 8_000
        let chargedTwice: Set<Int> = [84_209, 84_205, 84_202]
        for (index, order) in orderMeta.enumerated() {
            for _ in 0..<random.int(1...3) {
                items.append([String(items.count + 1), String(order.id), String(random.int(1...products.count)), String(random.int(1...3)),
                              String(format: "%.2f", Double(random.int(800...24_000)) / 100)])
            }
            guard order.status != "pending" else { continue }
            let card = String(format: "%04d", random.int(1_000...9_999))
            if random.chance(6) {
                paymentID += 1
                payments.append([String(paymentID), String(order.id), literal("failed"), order.total, literal(card), literal(stamp(order.created.addingTimeInterval(20)))])
            }
            paymentID += 1
            payments.append([String(paymentID), String(order.id), literal("succeeded"), order.total, literal(card), literal(stamp(order.created.addingTimeInterval(40)))])
            if chargedTwice.contains(order.id) {
                paymentID += 1
                payments.append([String(paymentID), String(order.id), literal("succeeded"), order.total, literal(card),
                                 literal(stamp(order.created.addingTimeInterval(40 + Double(random.int(50...110)))))])
            }
            if order.status == "refunded" {
                refunds.append([String(refunds.count + 1), String(paymentID), order.total, literal(random.pick(["damaged", "late", "wrong size", nil])),
                                literal(stamp(order.created.addingTimeInterval(86_400 * 3)))])
            }
            if ["shipped", "delivered", "refunded"].contains(order.status) {
                shipments.append([String(shipments.count + 1), String(order.id), literal(random.pick(["UPS", "DHL", "PTT", "FedEx"])),
                                  literal("1Z\(order.id)\(index % 97)"), literal(stamp(order.created.addingTimeInterval(86_400)))])
            }
            invoices.append([String(invoices.count + 1), String(order.id), literal("INV-\(order.id)"), order.total, literal(stamp(order.created))])
        }
        sql += batches("order_items", items)
        sql += batches("payments", payments)
        sql += batches("refunds", refunds)
        sql += batches("shipments", shipments)
        sql += batches("invoices", invoices)

        let keys = (1...40).map { index in
            [String(index), String(random.int(1...customerCount)), literal("tm_demo_\(String(random.next(), radix: 36))\(String(random.next(), radix: 36))"),
             literal(stamp(now.addingTimeInterval(-Double(index) * 86_400)))]
        }
        sql += batches("api_keys", keys)
        if pg { sql.append("ANALYZE") }
        return sql
    }

    private static func batches(_ table: String, _ rows: [[String]]) -> [String] {
        stride(from: 0, to: rows.count, by: 400).map { start in
            let chunk = rows[start..<min(start + 400, rows.count)]
            return "INSERT INTO \(table) VALUES " + chunk.map { "(" + $0.joined(separator: ", ") + ")" }.joined(separator: ", ")
        }
    }
}

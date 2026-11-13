struct Account {
    var owner: String
    var balance: Double

    mutating func deposit(_ amount: Double) { balance += amount }
    func statement() -> String { "\(owner): \(balance)" }
}

final class Bank {
    var accounts: [Account] = []
    let name: String

    init(name: String) { self.name = name }

    func open(owner: String) -> Account {
        let account: Account = Account(owner: owner, balance: 0)
        account⟨1⟩
        return account
    }

    func audit(_ target: Account) {
        target⟨2⟩
    }
}

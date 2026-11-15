struct User {
    var name: String
    var email: String
    private var secret: Int = 0

    func describe() -> String {
        name + " <" + email + ">"
    }
}

class Account {
    var balance: Int = 0
    func deposit(_ amount: Int) -> Int {
        balance += amount
        return balance
    }
}

class Admin: Account {
    var level: Int = 1
    func ban(_ user: User) -> Bool { true }
}

func makeAdmin(level: Int) -> Admin {
    let admin = Admin()
    admin.level = level
    return admin
}

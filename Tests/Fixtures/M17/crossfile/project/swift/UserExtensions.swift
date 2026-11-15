extension User {
    func greet(times: Int) -> String {
        String(repeating: "hi ", count: times) + name
    }

    fileprivate func hidden() {}
}

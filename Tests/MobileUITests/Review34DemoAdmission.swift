enum Review34DemoAdmission {
    static func admitted(revision: String?, optIn: String?, isPad: Bool,
                         signedOut: Bool, idle: Bool, credentialsEmpty: Bool) -> Bool {
        revision == "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
            && optIn == "prepared-final-page-only" && isPad && signedOut && idle && credentialsEmpty
    }

    static func credentialsAreEmpty(value: String?, placeholder: String?) -> Bool {
        guard let value else { return false }
        return value.isEmpty || (placeholder?.isEmpty == false && value == placeholder)
    }
}

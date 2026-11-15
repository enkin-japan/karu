use crate::models::User;

impl User {
    pub fn new(name: &str) -> User {
        User { name: name.to_string(), secret: 0 }
    }

    pub fn greet(&self) -> String {
        format!("hi {}", self.name)
    }
}

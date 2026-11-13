pub struct Config {
    pub name: String,
    pub retries: u32,
}

impl Config {
    pub fn validate(&self) -> bool {
        !self.name.is_empty()
    }

    pub fn with_retries(mut self, n: u32) -> Self {
        self.retries = n;
        self
    }
}

pub enum Mode {
    Fast,
    Safe,
}

fn run(cfg: &Config) {
    cfg⟨1⟩
}

fn main() {
    let cfg: Config = Config { name: "x".into(), retries: 1 };
    cfg⟨2⟩
}

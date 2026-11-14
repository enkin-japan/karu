function legacyFn(a, b) {
  return a + b;
}

class Legacy {
  constructor() {
    this.ready = true;
  }
  run() {
    return 1;
  }
}

module.exports = { legacyFn, Legacy };

// Member access samples (JavaScript).

class Counter {
  constructor(start = 0) {
    this.count = start;
    this.step = 1;
  }

  increment() {
    this.count += this.step;
    return this⟨1⟩;
  }

  reset() {
    this⟨2⟩
  }
}

class Basket {
  constructor() {
    this.fruits = [];
  }

  weigh() {
    return this.fruits.length;
  }
}

function makeUser() {
  return { name: 'Ada', age: 36 };
}

/** @param {string} label */
function show(label) {
  return label⟨3⟩;
}

function literals() {
  const name = 'abc';
  name⟨4⟩
  const items = [];
  items⟨5⟩
  const cache = new Map();
  cache⟨6⟩
  const config = { host: 'localhost', port: 8080 };
  config⟨7⟩
}

async function remote(url) {
  const res = await fetch(url);
  res⟨8⟩
}

function returns() {
  makeUser()⟨9⟩
  const counter = new Counter();
  counter⟨10⟩
}

function narrowing(v) {
  if (typeof v === 'string') {
    v⟨11⟩
  }
}

function incomplete() {
  const options = { verbose: true,
  const text = 'x';
  text⟨12⟩
}

function render(widget, order, user) {
  widget.mount();
  console.log(widget.width);
  widget⟨13⟩
  console.log(order.id, order.total);
  console.log(user.id, user.email, user.lastLogin);
  order⟨14⟩
}

export { Basket, show, literals, remote, returns, narrowing, incomplete, render };

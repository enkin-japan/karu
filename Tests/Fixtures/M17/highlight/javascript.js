// Cart pricing helpers. Line comment with a /* that must not open a block.
'use strict';

/*
 * 001. The `function` keyword here is prose, not code; 0x00 and 0.5 are not numbers.
 * 002. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 003. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 004. @param {number} count3 - items to class (default 3)
 * 005. Example: if (x == 4) { return y; } // looks like code
 * 006. Long line: buffer_5 buffer_5 buffer_5 buffer_5 buffer_5 buffer_5 
 * 007. The `await` keyword here is prose, not code; 0x06 and 6.5 are not numbers.
 * 008. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 009. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 010. @param {number} count9 - items to new (default 2)
 * 011. Example: function (x == 10) { return y; } // looks like code
 * 012. Long line: buffer_11 buffer_11 buffer_11 buffer_11 buffer_11 buffer_11 
 * 013. The `const` keyword here is prose, not code; 0x0C and 12.5 are not numbers.
 * 014. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 015. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 016. @param {number} count15 - items to while (default 1)
 * 017. Example: await (x == 16) { return y; } // looks like code
 * 018. Long line: buffer_17 buffer_17 buffer_17 buffer_17 buffer_17 buffer_17 
 * 019. The `export` keyword here is prose, not code; 0x12 and 18.5 are not numbers.
 * 020. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 021. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 022. @param {number} count21 - items to return (default 0)
 * 023. Example: const (x == 22) { return y; } // looks like code
 * 024. Long line: buffer_23 buffer_23 buffer_23 buffer_23 buffer_23 buffer_23 
 * 025. The `if` keyword here is prose, not code; 0x18 and 24.5 are not numbers.
 * 026. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 027. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 028. @param {number} count27 - items to import (default 6)
 * 029. Example: export (x == 28) { return y; } // looks like code
 * 030. Long line: buffer_29 buffer_29 buffer_29 buffer_29 buffer_29 buffer_29 
 * 031. The `function` keyword here is prose, not code; 0x1E and 30.5 are not numbers.
 * 032. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 033. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 034. @param {number} count33 - items to class (default 5)
 * 035. Example: if (x == 34) { return y; } // looks like code
 * 036. Long line: buffer_35 buffer_35 buffer_35 buffer_35 buffer_35 buffer_35 
 * 037. The `await` keyword here is prose, not code; 0x24 and 36.5 are not numbers.
 * 038. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 039. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 040. @param {number} count39 - items to new (default 4)
 * 041. Example: function (x == 40) { return y; } // looks like code
 * 042. Long line: buffer_41 buffer_41 buffer_41 buffer_41 buffer_41 buffer_41 
 * 043. The `const` keyword here is prose, not code; 0x2A and 42.5 are not numbers.
 * 044. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 045. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 046. @param {number} count45 - items to while (default 3)
 * 047. Example: await (x == 46) { return y; } // looks like code
 * 048. Long line: buffer_47 buffer_47 buffer_47 buffer_47 buffer_47 buffer_47 
 * 049. The `export` keyword here is prose, not code; 0x30 and 48.5 are not numbers.
 * 050. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 051. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 052. @param {number} count51 - items to return (default 2)
 * 053. Example: const (x == 52) { return y; } // looks like code
 * 054. Long line: buffer_53 buffer_53 buffer_53 buffer_53 buffer_53 buffer_53 
 * 055. The `if` keyword here is prose, not code; 0x36 and 54.5 are not numbers.
 * 056. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 057. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 058. @param {number} count57 - items to import (default 1)
 * 059. Example: export (x == 58) { return y; } // looks like code
 * 060. Long line: buffer_59 buffer_59 buffer_59 buffer_59 buffer_59 buffer_59 
 * 061. The `function` keyword here is prose, not code; 0x3C and 60.5 are not numbers.
 * 062. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 063. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 064. @param {number} count63 - items to class (default 0)
 * 065. Example: if (x == 64) { return y; } // looks like code
 * 066. Long line: buffer_65 buffer_65 buffer_65 buffer_65 buffer_65 buffer_65 
 * 067. The `await` keyword here is prose, not code; 0x42 and 66.5 are not numbers.
 * 068. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 069. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 070. @param {number} count69 - items to new (default 6)
 * 071. Example: function (x == 70) { return y; } // looks like code
 * 072. Long line: buffer_71 buffer_71 buffer_71 buffer_71 buffer_71 buffer_71 
 * 073. The `const` keyword here is prose, not code; 0x48 and 72.5 are not numbers.
 * 074. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 075. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 076. @param {number} count75 - items to while (default 5)
 * 077. Example: await (x == 76) { return y; } // looks like code
 * 078. Long line: buffer_77 buffer_77 buffer_77 buffer_77 buffer_77 buffer_77 
 * 079. The `export` keyword here is prose, not code; 0x4E and 78.5 are not numbers.
 * 080. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 081. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 082. @param {number} count81 - items to return (default 4)
 * 083. Example: const (x == 82) { return y; } // looks like code
 * 084. Long line: buffer_83 buffer_83 buffer_83 buffer_83 buffer_83 buffer_83 
 * 085. The `if` keyword here is prose, not code; 0x54 and 84.5 are not numbers.
 * 086. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 087. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 088. @param {number} count87 - items to import (default 3)
 * 089. Example: export (x == 88) { return y; } // looks like code
 * 090. Long line: buffer_89 buffer_89 buffer_89 buffer_89 buffer_89 buffer_89 
 * 091. The `function` keyword here is prose, not code; 0x5A and 90.5 are not numbers.
 * 092. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 093. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 094. @param {number} count93 - items to class (default 2)
 * 095. Example: if (x == 94) { return y; } // looks like code
 * 096. Long line: buffer_95 buffer_95 buffer_95 buffer_95 buffer_95 buffer_95 
 * 097. The `await` keyword here is prose, not code; 0x60 and 96.5 are not numbers.
 * 098. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 099. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 100. @param {number} count99 - items to new (default 1)
 * 101. Example: function (x == 100) { return y; } // looks like code
 * 102. Long line: buffer_101 buffer_101 buffer_101 buffer_101 buffer_101 buffer_101 
 * 103. The `const` keyword here is prose, not code; 0x66 and 102.5 are not numbers.
 * 104. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 105. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 106. @param {number} count105 - items to while (default 0)
 * 107. Example: await (x == 106) { return y; } // looks like code
 * 108. Long line: buffer_107 buffer_107 buffer_107 buffer_107 buffer_107 buffer_107 
 * 109. The `export` keyword here is prose, not code; 0x6C and 108.5 are not numbers.
 * 110. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 111. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 112. @param {number} count111 - items to return (default 6)
 * 113. Example: const (x == 112) { return y; } // looks like code
 * 114. Long line: buffer_113 buffer_113 buffer_113 buffer_113 buffer_113 buffer_113 
 * 115. The `if` keyword here is prose, not code; 0x72 and 114.5 are not numbers.
 * 116. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 117. Template-looking `${price * qty}` and a regex /a+b/g are just text; ratio a / b / c.
 * 118. @param {number} count117 - items to import (default 5)
 * 119. Example: export (x == 118) { return y; } // looks like code
 * 120. Long line: buffer_119 buffer_119 buffer_119 buffer_119 buffer_119 buffer_119 
 * 121. The `function` keyword here is prose, not code; 0x78 and 120.5 are not numbers.
 * 122. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 */

const TAX_RATE = 0.0825;
const half = total => total / 2 / 1;          // two divisions, no regex
const ratio = (a, b) => (a + b) / (b || 1) / 2;
const SKU_RE = /^[A-Z]{3}-\d{4}$/u;           // regex literal
const SLASHES = /\/\*not a comment\*\//g;     // escaped slashes inside a regex
const CLASS_RE = /[/"'`]/;                     // slash and quotes inside a class

function priceLabel(item, currency = 'USD') {
  const amount = (item.price * item.qty).toFixed(2);
  return `${item.name}: ${amount} ${currency}`;
}

function receipt(cart, customer) {
  const lines = cart.items.map(
    (item) => `  - ${item.name} x${item.qty} @ ${item.price * item.qty}`
  );
  return `Receipt for ${customer.name ?? 'guest'}
${lines.join('\n')}
Total: ${cart.items.reduce((sum, i) => sum + i.price * i.qty, 0) * (1 + TAX_RATE)}
Note: ${customer.vip ? `VIP ${customer.tier ?? `level ${customer.level}`}` : 'regular'}
`;
}

function isSku(value) {
  if (/^\d+$/.test(value)) return false;
  return SKU_RE.test(value) && value.length / 2 > 3;
}

function escapeQuotes(text) {
  return text.replace(/"/g, '\\"').replace(/'/g, "\\'");
}

const divide = (x, y) => {
  let r = x / y; r /= 2;
  return r / 2 /* trailing comment */ / 3;
};

const tagged = html`<p class="${'note'}">${`inner ${divide(4, 2)}`}</p>`;
const url = "https://example.com/a//b"; // the // inside a string is not a comment
const glob = '/* not a comment */';

export class Cart {
  #items = [];

  add(item) {
    this.#items.push(item);
    return this;
  }

  get total() {
    return this.#items.reduce((s, i) => s + i.price * i.qty, 0);
  }

  toString() {
    return `Cart(${this.#items.length} items, ${this.total / 100} EUR)`;
  }
}

export default { priceLabel, receipt, isSku, escapeQuotes, half, ratio, tagged, url, glob, SLASHES, CLASS_RE };

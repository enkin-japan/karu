// shader_cache.cpp — compiles and caches GLSL snippets.
#include <iostream>
#include <map>
#include <string>
#include <string_view>

/* Block comment with code-looking text:
   std::string s = "not a string"; return 0;
   R"(not a raw string)" either.
*/

namespace gfx {

constexpr const char* kVertex = R"glsl(
#version 330 core
layout(location = 0) in vec3 aPos;   // a GLSL comment, still raw string
void main() {
    gl_Position = vec4(aPos, 1.0);   /* also raw */
    // a fake terminator )" does not close this one: the delimiter is glsl
}
)glsl";

constexpr const char* kPlainRaw = R"(C:\path\with\backslashes\n and "quotes")";
const auto kUtf8Raw = u8R"x(unicode ✓ text with )" inside)x";
const char kQuote = '"';
const char* kEscaped = "line one\n\"two\" /* not a comment */";

template <typename Key, typename Value>
class Cache {
public:
    explicit Cache(std::size_t limit) : limit_(limit) {}

    bool put(const Key& key, Value value) {
        if (entries_.size() >= limit_) {
            return false; // full
        }
        entries_.emplace(key, std::move(value));
        return true;
    }

    const Value* get(const Key& key) const {
        auto it = entries_.find(key);
        return it == entries_.end() ? nullptr : &it->second;
    }

    std::size_t size() const noexcept { return entries_.size(); }

private:
    std::size_t limit_;
    std::map<Key, Value> entries_;
};

std::string describe(std::string_view name, int lines) {
    return std::string(name) + ": " + std::to_string(lines) + " lines";
}

} // namespace gfx

int main() {
    gfx::Cache<std::string, std::string> cache(8);
    cache.put("vertex", gfx::kVertex);
    cache.put("plain", gfx::kPlainRaw);
    auto ratio = cache.size() / 2 / 1.0;
    std::cout << gfx::describe("vertex", 6) << ' ' << ratio << kQuote << '\n';
    std::cout << gfx::kEscaped << gfx::kUtf8Raw << std::endl;
    /* multi-line comment
       closing on a later line */ return 0;
}

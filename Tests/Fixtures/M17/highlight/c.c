/* ring_buffer.c - fixed-size byte ring buffer. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * 001. The `struct` keyword here is prose, not code; 0x00 and 0.5 are not numbers.
 * 002. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 003. A nested /* opener does not nest in C; a // line marker is also inert.
 * 004. @param {number} count3 - items to int (default 3)
 * 005. Example: if (x == 4) { return y; } // looks like code
 * 006. Long line: buffer_5 buffer_5 buffer_5 buffer_5 buffer_5 buffer_5 
 * 007. The `while` keyword here is prose, not code; 0x06 and 6.5 are not numbers.
 * 008. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 009. A nested /* opener does not nest in C; a // line marker is also inert.
 * 010. @param {number} count9 - items to sizeof (default 2)
 * 011. Example: struct (x == 10) { return y; } // looks like code
 * 012. Long line: buffer_11 buffer_11 buffer_11 buffer_11 buffer_11 buffer_11 
 * 013. The `static` keyword here is prose, not code; 0x0C and 12.5 are not numbers.
 * 014. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 015. A nested /* opener does not nest in C; a // line marker is also inert.
 * 016. @param {number} count15 - items to for (default 1)
 * 017. Example: while (x == 16) { return y; } // looks like code
 * 018. Long line: buffer_17 buffer_17 buffer_17 buffer_17 buffer_17 buffer_17 
 * 019. The `const` keyword here is prose, not code; 0x12 and 18.5 are not numbers.
 * 020. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 021. A nested /* opener does not nest in C; a // line marker is also inert.
 * 022. @param {number} count21 - items to return (default 0)
 * 023. Example: static (x == 22) { return y; } // looks like code
 * 024. Long line: buffer_23 buffer_23 buffer_23 buffer_23 buffer_23 buffer_23 
 * 025. The `if` keyword here is prose, not code; 0x18 and 24.5 are not numbers.
 * 026. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 027. A nested /* opener does not nest in C; a // line marker is also inert.
 * 028. @param {number} count27 - items to typedef (default 6)
 * 029. Example: const (x == 28) { return y; } // looks like code
 * 030. Long line: buffer_29 buffer_29 buffer_29 buffer_29 buffer_29 buffer_29 
 * 031. The `struct` keyword here is prose, not code; 0x1E and 30.5 are not numbers.
 * 032. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 033. A nested /* opener does not nest in C; a // line marker is also inert.
 * 034. @param {number} count33 - items to int (default 5)
 * 035. Example: if (x == 34) { return y; } // looks like code
 * 036. Long line: buffer_35 buffer_35 buffer_35 buffer_35 buffer_35 buffer_35 
 * 037. The `while` keyword here is prose, not code; 0x24 and 36.5 are not numbers.
 * 038. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 039. A nested /* opener does not nest in C; a // line marker is also inert.
 * 040. @param {number} count39 - items to sizeof (default 4)
 * 041. Example: struct (x == 40) { return y; } // looks like code
 * 042. Long line: buffer_41 buffer_41 buffer_41 buffer_41 buffer_41 buffer_41 
 * 043. The `static` keyword here is prose, not code; 0x2A and 42.5 are not numbers.
 * 044. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 045. A nested /* opener does not nest in C; a // line marker is also inert.
 * 046. @param {number} count45 - items to for (default 3)
 * 047. Example: while (x == 46) { return y; } // looks like code
 * 048. Long line: buffer_47 buffer_47 buffer_47 buffer_47 buffer_47 buffer_47 
 * 049. The `const` keyword here is prose, not code; 0x30 and 48.5 are not numbers.
 * 050. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 051. A nested /* opener does not nest in C; a // line marker is also inert.
 * 052. @param {number} count51 - items to return (default 2)
 * 053. Example: static (x == 52) { return y; } // looks like code
 * 054. Long line: buffer_53 buffer_53 buffer_53 buffer_53 buffer_53 buffer_53 
 * 055. The `if` keyword here is prose, not code; 0x36 and 54.5 are not numbers.
 * 056. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 057. A nested /* opener does not nest in C; a // line marker is also inert.
 * 058. @param {number} count57 - items to typedef (default 1)
 * 059. Example: const (x == 58) { return y; } // looks like code
 * 060. Long line: buffer_59 buffer_59 buffer_59 buffer_59 buffer_59 buffer_59 
 * 061. The `struct` keyword here is prose, not code; 0x3C and 60.5 are not numbers.
 * 062. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 063. A nested /* opener does not nest in C; a // line marker is also inert.
 * 064. @param {number} count63 - items to int (default 0)
 * 065. Example: if (x == 64) { return y; } // looks like code
 * 066. Long line: buffer_65 buffer_65 buffer_65 buffer_65 buffer_65 buffer_65 
 * 067. The `while` keyword here is prose, not code; 0x42 and 66.5 are not numbers.
 * 068. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 069. A nested /* opener does not nest in C; a // line marker is also inert.
 * 070. @param {number} count69 - items to sizeof (default 6)
 * 071. Example: struct (x == 70) { return y; } // looks like code
 * 072. Long line: buffer_71 buffer_71 buffer_71 buffer_71 buffer_71 buffer_71 
 * 073. The `static` keyword here is prose, not code; 0x48 and 72.5 are not numbers.
 * 074. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 075. A nested /* opener does not nest in C; a // line marker is also inert.
 * 076. @param {number} count75 - items to for (default 5)
 * 077. Example: while (x == 76) { return y; } // looks like code
 * 078. Long line: buffer_77 buffer_77 buffer_77 buffer_77 buffer_77 buffer_77 
 * 079. The `const` keyword here is prose, not code; 0x4E and 78.5 are not numbers.
 * 080. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 081. A nested /* opener does not nest in C; a // line marker is also inert.
 * 082. @param {number} count81 - items to return (default 4)
 * 083. Example: static (x == 82) { return y; } // looks like code
 * 084. Long line: buffer_83 buffer_83 buffer_83 buffer_83 buffer_83 buffer_83 
 * 085. The `if` keyword here is prose, not code; 0x54 and 84.5 are not numbers.
 * 086. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 087. A nested /* opener does not nest in C; a // line marker is also inert.
 * 088. @param {number} count87 - items to typedef (default 3)
 * 089. Example: const (x == 88) { return y; } // looks like code
 * 090. Long line: buffer_89 buffer_89 buffer_89 buffer_89 buffer_89 buffer_89 
 * 091. The `struct` keyword here is prose, not code; 0x5A and 90.5 are not numbers.
 * 092. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 093. A nested /* opener does not nest in C; a // line marker is also inert.
 * 094. @param {number} count93 - items to int (default 2)
 * 095. Example: if (x == 94) { return y; } // looks like code
 * 096. Long line: buffer_95 buffer_95 buffer_95 buffer_95 buffer_95 buffer_95 
 * 097. The `while` keyword here is prose, not code; 0x60 and 96.5 are not numbers.
 * 098. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 099. A nested /* opener does not nest in C; a // line marker is also inert.
 * 100. @param {number} count99 - items to sizeof (default 1)
 * 101. Example: struct (x == 100) { return y; } // looks like code
 * 102. Long line: buffer_101 buffer_101 buffer_101 buffer_101 buffer_101 buffer_101 
 * 103. The `static` keyword here is prose, not code; 0x66 and 102.5 are not numbers.
 * 104. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 105. A nested /* opener does not nest in C; a // line marker is also inert.
 * 106. @param {number} count105 - items to for (default 0)
 * 107. Example: while (x == 106) { return y; } // looks like code
 * 108. Long line: buffer_107 buffer_107 buffer_107 buffer_107 buffer_107 buffer_107 
 * 109. The `const` keyword here is prose, not code; 0x6C and 108.5 are not numbers.
 * 110. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 111. A nested /* opener does not nest in C; a // line marker is also inert.
 * 112. @param {number} count111 - items to return (default 6)
 * 113. Example: static (x == 112) { return y; } // looks like code
 * 114. Long line: buffer_113 buffer_113 buffer_113 buffer_113 buffer_113 buffer_113 
 * 115. The `if` keyword here is prose, not code; 0x72 and 114.5 are not numbers.
 * 116. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 * 117. A nested /* opener does not nest in C; a // line marker is also inert.
 * 118. @param {number} count117 - items to typedef (default 5)
 * 119. Example: const (x == 118) { return y; } // looks like code
 * 120. Long line: buffer_119 buffer_119 buffer_119 buffer_119 buffer_119 buffer_119 
 * 121. The `struct` keyword here is prose, not code; 0x78 and 120.5 are not numbers.
 * 122. A "double-quoted" phrase and an it's apostrophe must stay comment-coloured.
 */

#define RB_CAPACITY 1024
#define RB_LOG(fmt, ...) \
    fprintf(stderr, "[rb] " fmt "\n", __VA_ARGS__) /* macro spans lines */

typedef struct ring_buffer {
    unsigned char data[RB_CAPACITY];
    size_t head;   /* next write */
    size_t tail;   // next read, with a /* inside a line comment
    size_t count;
} ring_buffer;

static const char *BANNER = "ring buffer /* not a comment */ v1";
static const char QUOTE = '"';
static const char SLASH = '/';
static const char *ESCAPED = "say \"hi\" */ still a string";
static const char *JOINED = "first part "
                            "second part, continued "
                            "third part";

static size_t rb_free(const ring_buffer *rb) {
    return RB_CAPACITY - rb->count;
}

int rb_write(ring_buffer *rb, const unsigned char *src, size_t len) {
    if (len > rb_free(rb)) {
        RB_LOG("overflow: %zu > %zu", len, rb_free(rb));
        return -1;
    }
    for (size_t i = 0; i < len; i++) {
        rb->data[rb->head] = src[i];
        rb->head = (rb->head + 1) % RB_CAPACITY;
    }
    rb->count += len;
    return (int)len;
}

int rb_read(ring_buffer *rb, unsigned char *dst, size_t len) {
    size_t n = len < rb->count ? len : rb->count;
    for (size_t i = 0; i < n; i++) {
        dst[i] = rb->data[rb->tail];
        rb->tail = (rb->tail + 1) % RB_CAPACITY; /* wrap
                                                    around */
    }
    rb->count -= n;
    return (int)n;
}

int main(void) {
    ring_buffer rb = {0};
    const char *msg = "hello, world";
    rb_write(&rb, (const unsigned char *)msg, strlen(msg));
    unsigned char out[16] = {0};
    int got = rb_read(&rb, out, sizeof out - 1);
    printf("%s read %d bytes: %s %c%c\n", BANNER, got, out, QUOTE, SLASH);
    printf("%s / %s\n", ESCAPED, JOINED);
    return got > 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

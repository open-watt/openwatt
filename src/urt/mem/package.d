module urt.mem;

public import core.stdc.stddef : wchar_t;

public import urt.lifetime : emplace, moveEmplace, forward, move;
public import urt.mem.allocator;


extern(C)
{
nothrow @nogc:
    void* alloca(size_t size);

    void* memcpy(void* dest, const void* src, size_t n);
    void* memmove(void* dest, const void* src, size_t n);
    void* memset(void* s, int c, size_t n);
    void* memzero(void* s, size_t n) => memset(s, 0, n);

    size_t strlen(const char* s);
    int strcmp(const char* s1, const char* s2);
    char* strcpy(char* dest, const char* src);
    char* strcat(char* dest, const char* src);

    size_t wcslen(const wchar_t* s);
//    wchar_t* wcscpy(wchar_t* dest, const wchar_t* src);
//    wchar_t* wcscat(wchar_t* dest, const wchar_t* src);
//    wchar_t* wcsncpy(wchar_t* dest, const wchar_t* src, size_t n);
//    wchar_t* wcsncat(wchar_t* dest, const wchar_t* src, size_t n);
}

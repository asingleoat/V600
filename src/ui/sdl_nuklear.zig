//! Shared SDL3/Nuklear C import for the native UI module. Every UI file must
//! use this single instance so the imported C types unify across modules.

pub const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cDefine("NK_INCLUDE_FIXED_TYPES", "1");
    @cDefine("NK_INCLUDE_STANDARD_IO", "1");
    @cDefine("NK_INCLUDE_STANDARD_VARARGS", "1");
    @cDefine("NK_INCLUDE_DEFAULT_ALLOCATOR", "1");
    @cDefine("NK_INCLUDE_VERTEX_BUFFER_OUTPUT", "1");
    @cDefine("NK_INCLUDE_FONT_BAKING", "1");
    @cDefine("NK_INCLUDE_DEFAULT_FONT", "1");
    @cInclude("SDL3/SDL.h");
    @cInclude("nuklear.h");
});

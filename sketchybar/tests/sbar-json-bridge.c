#include <dlfcn.h>
#include <stdbool.h>
#include <lua.h>
#include <lauxlib.h>

typedef bool (*JSONToLuaTable)(lua_State *, const char *);
static void *sbarlua_handle = NULL;
static JSONToLuaTable converter = NULL;

static int decode(lua_State *state) {
    const char *library = luaL_checkstring(state, 1);
    const char *document = luaL_checkstring(state, 2);
    if (sbarlua_handle == NULL) {
        sbarlua_handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
        if (sbarlua_handle == NULL) {
            return luaL_error(state, "SbarLua decoder is unavailable");
        }
        converter = (JSONToLuaTable)dlsym(sbarlua_handle, "json_to_lua_table");
        if (converter == NULL) {
            return luaL_error(state, "SbarLua decoder symbol is unavailable");
        }
    }
    if (!converter(state, document)) {
        return luaL_error(state, "SbarLua rejected the JSON document");
    }
    return 1;
}

int luaopen_sbar_json_bridge(lua_State *state) {
    lua_newtable(state);
    lua_pushcfunction(state, decode);
    lua_setfield(state, -2, "decode");
    return 1;
}

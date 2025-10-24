// SPDX-License-Identifier: MPL-2.0
const std = @import("std");

pub fn build(b: *std.Build) !void {
    var o = try Options.make(b);
    const upstream = b.dependency("upstream", .{ .target = o.target, .optimize = o.optimize });

    const shared = try o.getShared(b, upstream);
    if (o.shared) b.installArtifact(shared);

    const static = try o.getStatic(b, upstream);
    if (o.static) b.installArtifact(static);
}

pub const Options = struct {
    pub const HeapMode = enum(u1) {
        stack = 0,
        heap = 1,
    };

    pub const MemoryAccess = enum(u2) {
        memcpy = 0,
        packed_stmt = 1,
        direct = 2,
    };

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    static: bool,
    shared: bool,

    strip: bool,

    tsan: bool,
    ubsan: bool,

    freestanding: bool,

    heap_mode: HeapMode,

    memory_access: ?MemoryAccess,

    pub fn make(b: *std.Build) !Options {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),

            .static = b.option(bool, "static", "build static library (true)") orelse true,
            .shared = b.option(bool, "shared", "build shared library (true)") orelse true,

            .strip = b.option(bool, "strip", "strip output (false)") orelse false,

            .ubsan = b.option(bool, "ubsan", "use UBSanitizer (false)") orelse false,
            .tsan = b.option(bool, "tsan", "use ThreadSanitizer (false)") orelse false,

            .freestanding = b.option(bool, "freestanding", "build without libc") orelse false,
            .heap_mode = b.option(HeapMode, "heap_mode", "where to allocate internal buffers (stack)") orelse .stack,
            .memory_access = b.option(MemoryAccess, "memory_access", "how to access unaligned memory (memcpy)") orelse null,
        };
    }

    pub fn getStatic(o: Options, b: *std.Build, u: *std.Build.Dependency) !*std.Build.Step.Compile {
        const lib = b.addLibrary(.{
            .name = "lz4",
            .root_module = b.createModule(.{
                .target = o.target,
                .optimize = o.optimize,
                .strip = o.strip,
            }),
            .linkage = .static,
        });
        try o.addCpp(u, lib);
        if (!o.freestanding) {
            lib.installHeader(u.path("lib/lz4frame_static.h"), "lz4frame_static.h");
        }
        return lib;
    }

    pub fn getShared(o: Options, b: *std.Build, u: *std.Build.Dependency) !*std.Build.Step.Compile {
        const lib = b.addLibrary(.{
            .name = "lz4",
            .root_module = b.createModule(.{
                .target = o.target,
                .optimize = o.optimize,
                .strip = o.strip,
            }),
            .linkage = .dynamic,
        });
        try o.addCpp(u, lib);
        return lib;
    }

    pub fn addCpp(o: *const Options, u: *std.Build.Dependency, c: *std.Build.Step.Compile) !void {
        const flags_freestanding: []const []const u8 = &.{
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Wcast-qual",
            "-Wcast-align",
            "-Wshadow",
            "-Wswitch-enum",
            "-Wdeclaration-after-statement",
            "-Wstrict-prototypes",
            "-Wundef",
            "-Wpointer-arith",
            "-Wstrict-aliasing=1",
            "-ffreestanding",
        };

        const flags_libc = flags_freestanding[0 .. flags_freestanding.len - 1];

        const files_libc: []const []const u8 = &.{
            "lz4.c",
            "lz4hc.c",
            "lz4frame.c",
            "xxhash.c",
            "lz4file.c",
        };

        const files_freestanding = files_libc[0 .. files_libc.len - 3];

        c.addCSourceFiles(.{
            .files = if (o.freestanding) files_freestanding else files_libc,
            .flags = if (o.freestanding) flags_freestanding else flags_libc,
            .root = u.path("lib"),
        });

        if (o.freestanding) {
            // FIXME: I don't know if it makes any sense to reference
            // memcpy/memset/memmove from compiler_rt, or how to do
            // that, hence, yolo
            c.root_module.addCMacro("LZ4_FREESTANDING", "1");
            c.root_module.addCMacro(
                "LZ4_memcpy(__dest, __src, __n)",
                "do {" ++
                    "    for (size_t __i = 0; __i < (__n); __i++)" ++
                    "        ((char *)(__dest))[__i] = ((const char *)(__src))[__i];" ++
                    "} while (0)",
            );

            c.root_module.addCMacro(
                "LZ4_memset(__s, __c, __n)",
                "do {" ++
                    "    for (size_t __i = 0; __i < (__n); __i++)" ++
                    "        ((char *)(__s))[__i] = (__c);" ++
                    "} while (0)",
            );
            c.root_module.addCMacro(
                "LZ4_memmove(__dest, __src, __n)",
                "do {" ++
                    "    const char *__s = (const void *)(__src);" ++
                    "    char *__d = (void *)(__dest);" ++
                    "    uintptr_t __si = (uintptr_t)(__src);" ++
                    "    uintptr_t __di = (uintptr_t)(__dest);" ++
                    "    if (__di > __si) {" ++
                    "        size_t __i = (__n);" ++
                    "        while (__i != 0) {" ++
                    "            __i -= 1;" ++
                    "            __d[__i] = __s[__i];" ++
                    "        }" ++
                    "    } else {" ++
                    "        for (size_t __i = 0; __i < (__n); __i++)" ++
                    "            __d[__i] = __s[__i];" ++
                    "    }" ++
                    "} while (0)",
            );
        } else {
            c.linkLibC();
        }

        c.root_module.sanitize_c = if (o.ubsan) .full else .off;
        c.root_module.sanitize_thread = o.tsan;

        if (o.memory_access) |ma| {
            c.root_module.addCMacro("LZ4_FORCE_MEMORY_ACCESS", switch (ma) {
                .memcpy => "0",
                .packed_stmt => "1",
                .direct => "2",
            });
        }
        c.root_module.addCMacro("LZ4_HEAPMODE", switch (o.heap_mode) {
            .stack => "0",
            .heap => "1",
        });

        c.root_module.addCMacro("XXH_NAMESPACE", "LZ4_");

        c.installHeader(u.path("lib/lz4.h"), "lz4.h");
        c.installHeader(u.path("lib/lz4hc.h"), "lz4hc.h");
        if (!o.freestanding) {
            c.installHeader(u.path("lib/lz4frame.h"), "lz4frame.h");
            c.installHeader(u.path("lib/lz4file.h"), "lz4file.h");
        }
    }
};

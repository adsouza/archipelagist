# X11 headers for Linux builds

Headers from libX11, libXrandr, libXinerama, libXi, libXcursor, libXrender,
libXfixes, libXext and xorgproto (Ubuntu 24.04 packages), under the licenses in
COPYING. build.zig compiles raylib's GLFW against these so the game builds for
Linux on any host, including macOS. GLFW loads the libraries themselves with
dlopen at startup, so nothing here is linked.

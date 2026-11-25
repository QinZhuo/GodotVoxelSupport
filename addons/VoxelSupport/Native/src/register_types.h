#ifndef VOXEL_NATIVE_REGISTER_TYPES_H
#define VOXEL_NATIVE_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

// 【为什么这里没有 initialize_/uninitialize_ 的声明】这两个函数是 register_types.cpp 内部的
// 实现细节（文件内定义、文件内注册进 InitObject），本头文件不被任何其他 TU 包含，声明它们没有
// 任何用处。此前这里声明的是 initialize_VoxelSupportNative_module（大写 V/S/N、带 Native），
// 而实现叫 initialize_voxelsupport_module —— 名字对不上，任何将来真去调到它的 TU 都会链接失败。
// 现在只保留"确实有人需要"的那一个：入口符号由 register_types.cpp 自己 extern "C" 定义，
// 无需声明。若将来要跨 TU 调用，请连同实现一起改名后再在此声明。

#endif // VOXEL_NATIVE_REGISTER_TYPES_H

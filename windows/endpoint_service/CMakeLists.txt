cmake_minimum_required(VERSION 3.15)
project(ligament_endpoint LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(ligament_endpoint endpoint_service.cpp)
target_link_libraries(ligament_endpoint PRIVATE winhttp ws2_32 advapi32)

if(MSVC)
    # статический рантайм: служба не должна тянуть vcruntime.dll
    set_property(TARGET ligament_endpoint PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()

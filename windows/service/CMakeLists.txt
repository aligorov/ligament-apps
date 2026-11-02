cmake_minimum_required(VERSION 3.15)
project(ligament_service LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

add_executable(ligament_service service.cpp)
target_link_libraries(ligament_service PRIVATE wtsapi32 advapi32 user32)

if(MSVC)
    # статический рантайм: служба не должна тянуть vcruntime.dll
    set_property(TARGET ligament_service PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
    target_compile_options(ligament_service PRIVATE /guard:cf /GS)
    target_link_options(ligament_service PRIVATE /DYNAMICBASE /HIGHENTROPYVA /NXCOMPAT /GUARD:CF)
endif()

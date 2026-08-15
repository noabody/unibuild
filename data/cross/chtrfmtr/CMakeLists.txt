cmake_minimum_required(VERSION 3.16)
project(ChtrFmtr LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Enable Qt MOC, UIC, and RCC code generation
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

# Find Qt6 components
find_package(Qt6 COMPONENTS Core Widgets REQUIRED)

# -----------------------------------------------------------------------------
# PCRE2 Integration (Downloads and builds pcre2-8 automatically)
# -----------------------------------------------------------------------------
include(FetchContent)

set(PCRE2_BUILD_PCRE2_8 ON CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_16 OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_32 OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_TESTS OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    pcre2
    GIT_REPOSITORY https://github.com/PCRE2Project/pcre2.git
    GIT_TAG        pcre2-10.44
)
FetchContent_MakeAvailable(pcre2)

# -----------------------------------------------------------------------------
# Executable Target
# -----------------------------------------------------------------------------
find_package(Qt6 REQUIRED COMPONENTS Widgets Xml)
add_executable(ChtrFmtr
    main.cpp
    # Add your translated .cpp and .h source files here
)

# Specify 8-bit code units globally for PCRE2 headers
target_compile_definitions(ChtrFmtr PRIVATE PCRE2_CODE_UNIT_WIDTH=8)

# Link Qt6 and static PCRE2-8 library
target_link_libraries(ChtrFmtr PRIVATE
    Qt6::Widgets
    Qt6::Xml
    pcre2-8
)
if(MSVC)
  target_compile_options(ChtrFmtr PRIVATE /W4)
else()
  target_compile_options(ChtrFmtr PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

default: build

build:
    nimble build --errorMax:500 --verbose -d:release --mm:orc --opt:speed --passC:-O3

build-debug:
    nimble build -d:debug --lineTrace:off --stackTrace:off

run: build
    ./main

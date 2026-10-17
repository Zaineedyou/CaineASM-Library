NASM ?= nasm
CC   ?= cc
AR   ?= ar
LD   ?= ld
OBJCOPY ?= objcopy

MODS := util json net gateway core rest helpers interact build cmd upload events crash presence
OBJS := $(addprefix build/,$(addsuffix .o,$(MODS)))
LIBS := -l:libcurl.so.4 -pthread

all: build/libcaineasm.a

build/%.o: src/%.asm src/defs.inc
	@mkdir -p build
	$(NASM) -f elf64 -g -F dwarf -I src/ -o $@ $<

# one relocatable object; only the casm_* API stays global (see api.txt)
build/caineasm_all.o: $(OBJS)
	$(LD) -r -o $@ $(OBJS)

build/caineasm.o: build/caineasm_all.o api.txt
	$(OBJCOPY) --keep-global-symbols=api.txt $< $@

build/libcaineasm.a: build/caineasm.o
	$(AR) rcs $@ $<

build/test_caineasm: tests/test_caineasm.c build/libcaineasm.a include/caineasm.h
	$(CC) -O1 -g -Wall -Wextra -Iinclude -o $@ tests/test_caineasm.c build/libcaineasm.a $(LIBS)

build/ping_bot: examples/ping_bot.c build/libcaineasm.a include/caineasm.h
	$(CC) -O1 -Wall -Wextra -Iinclude -o $@ examples/ping_bot.c build/libcaineasm.a $(LIBS)

build/slash_bot: examples/slash_bot.c build/libcaineasm.a include/caineasm.h
	$(CC) -O1 -Wall -Wextra -Iinclude -o $@ examples/slash_bot.c build/libcaineasm.a $(LIBS)

example: build/ping_bot build/slash_bot

# end-to-end test against a local TLS mock of Discord (tests/mock_discord.py)
test: build/test_caineasm
	python3 tests/run_test.py build/test_caineasm

valgrind: build/test_caineasm
	VALGRIND=1 python3 tests/run_test.py build/test_caineasm

clean:
	rm -rf build

.PHONY: all test valgrind example clean

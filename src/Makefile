# Very simple Makefile for ficus (thanks to OCamlbuild)

.PHONY: all clean byte native profile debug sanity test

OCB_FLAGS = -pkgs str,unix
OCB = ocamlbuild $(OCB_FLAGS)

all: native # byte profile debug

clean:
	$(OCB) -clean
	@rm -f parser.ml
	@rm -f parser.mli
	@rm -f parser.output
	@rm -f *.pgm
	@rm -f *.c

native:
	$(OCB) ficus.native
	@cp ficus.native ficus

byte:
	$(OCB) ficus.byte

debug:
	$(OCB) -tag debug ficus.d.byte

test: native
	./ficus -run ../test/test_all.fx

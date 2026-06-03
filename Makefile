PACKAGES=$(wildcard *.el)
ELCFILES=$(PACKAGES:.el=.elc)

%.elc : %.el
	run-emacs -L ~/.emacs.d/user-lisp -l ~/.emacs.d/init.el -batch -f batch-byte-compile $<

all: $(ELCFILES)

cleanish:
	rm -f *~

clean: cleanish
	rm -f *.elc

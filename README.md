# Coff

This repository contains a COFF parser with very basic dumping features.
The goal of this project is to learn more about the format, before building a linker for the file format.
This project will never be a full objdump replacement as only the basic features are required to learn
just enough to start building a linker.

The following options are currently supported:
```
Usage: coff [options] [files...]

Options:
-H, --help                         Print this help and exit
-h, --headers                      Print the section headers of the object file
-t, --syms                         Print the symbol table
```

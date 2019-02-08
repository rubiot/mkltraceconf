# signatures
Tool that generates an ltrace config file for a dynamic library.

    ./signatures.pl <libname.so>

# genprototypes
Tool that generates function prototypes for all functions of a C source file.

    ./genprototypes.pl [options] <source-file>

    options:
      --max-columns=<N>, -c Max number of columns per line
      --run-tests, -t       Run unit tests only
# gencpp
Tool that receives a C++ header file and generates its .cpp skeleton file. **Work in progress**.

    ./gencpp.pl6 -h=<C++ header>

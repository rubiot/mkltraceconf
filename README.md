# signatures
Tool that generates an ltrace config file for a dynamic library.

    ./signatures.pl <libname.so>

# genprototypes
Tool that generates function prototypes for all functions of a C source file.

    ./genprototypes.pl [options] <source-file>

    Options:
      --max-columns=<N>, -c Max number of columns per line
      --run-tests, -t       Run unit tests only
# gencpp
Tool that receives a C++ header file and generates its .cpp skeleton file. **Work in progress**.

    ./gencpp.pl6 -h=<C++ header>

# genunittest.pl
Tool that receives a C source file and generates a unit test skeleton file with all external functions already mocked (using fff.h), except for system calls. Too dependent on GCC version.

    ./genunittest.pl [options] -- <.c file>
    
    Options:
      --exclude=<pattern> Excluded files
             -x <pattern>
      
      --test-func=<funcs> List of functions to which test cases should be created
               -f <funcs>
      
           --path=<paths> Extra dirs to search for included headers
               -p <paths>
               
              --overwrite Force overwriting of the output file if it exists
                       -o
                       
              --int-tests Try and generate also a integration tests module
                       -i
                       
            --interactive Activates interactive mode
                       -n
                       
# imported_symbols.pl
Tool that lists all imported symbols of a binary file, specifying what dynamic libraries each symbol comes from.

    ./imported_symbols.pl <binary>

# ip-range.pl
Tool that generates custom IPv4 ranges.

    ./ip-range.pl <first-IPv4-address> <count>
    
    e.g: ./ip-range.pl 192.168.1.1 3
            192.168.1.1
            192.168.1.2
            192.168.1.3

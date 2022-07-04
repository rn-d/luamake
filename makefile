#variables, just list sources
#varname = filename1 filename2 ...

sources1 =in1.c in2.c
sources2 =in3.c
#this will create new variable by concatenating 2 already defined/computed ones
sources =$(sources1) $(sources2)
#this goes through sources file list and replaces .c extension with .o to make objects list
objects =$(patsubst $(sources),%.c,%.o)

#first target is build - by default

#target 1
in.exe : in1.o in2.o in3.o in1.c in2.c in3.c
	dir > in.exe

#target 2
in1.c in2.c :
	dir > in1.c
	dir > in2.c

#target 3
in3.c :
	dir > in3.c

#target 4
#here variable sources was use instead of 'in1.c in2.c in3.c'
#and variable objects ...

$(objects) : $(sources)
	copy $< $@
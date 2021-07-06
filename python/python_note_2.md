python note 2
=============

v0.1 2015.5.23 Sherlock init part4
v0.2 2015.5.31 Sherlock add part5

4. 函数
-------
* 函数基础

>	 #!/usr/bin/python
>	 
>	 def test_add(a, b):
>		return a + b
>	 
>	 print "1 + 2 =", test_add(1, 2)
>	 
>	 add_test = test_add
>	 print "1 + 2 =", add_test(1, 2)
>	 
>	 # need "pass" to fill this "none content function"
>	 def nop():
>		pass
>	 
>	 # default input
>	 def ball(r, color = "red", vendor = "A", llist = [1, 2, 3]):
>		llist.append(4)
>		print r
>		print color
>		print vendor
>		print llist
>	 
>	 print "test_1"
>	 ball(5)
>	 
>	 print "test_2"
>	 ball(5, "blue")
>	 
>	 print "test_3"
>	 ball(5, vendor = "B")
>	 
>	 print "test_4"
>	 ball(5, llist = [4, 5, 6])
>	 ball(5)
>	 
>	 # variable input
>	 print
>	 print "variable input test"
>	 def sum(*number):
>		sum = 0
>		for i in number:
>			sum = sum + i
>		return sum
>	 print "sum is", sum(1, 2, 3)
>
>	 num = [1, 2, 3, 4]
>	 print "sum is", sum(*num)
>	 
>	 # key word input
>	 print
>	 print "key word input test"
>	 def key_test(a, b, **c):
>		print a
>		print b
>		print c
>	 print  "key is", key_test(1, 2)
>	 print
>	 print  "key is", key_test(1, 2, name = "Sherlock")
>	 print
>	 dict_test = {"name" : "John", "age" : 12}
>	 print  "key is", key_test(1, 2, **dict_test)

** 函数名是一个指向函数对象的引用，所以可以把一个函数名赋值给一个变量
** 函数的参数可以是默认参数，可变参数，关键字参数等。
   当函数带默认参数时，默认参数需要是不可变参数。不然就像上面代码中显示的那样，
   如果函数中改变这个参数的值，以后这个参数的值相应的也都改变了。函数可以带可变
   参数, 可变参数可以直接传入函数，也可以先把所有参数组成一个列表，再通过*list
   传入。通过**dictionary的方式可以传入一个字典。

4. 面向对象
-----------

>	 #!/usr/bin/python
>	 
>	 class ball(object):
>		def __init__(self, r, color = "green", vendor = "A"):
>			# init r, but we need not to declare r
>			self.r = r
>			self.color = color
>			# private element
>			self.__vendor = vendor
>			
>		def run(self):
>			print "ball is running"
>		def show_color(self):
>			print "color of ball is", self.color
>	 
>	 # init an instance
>	 ball_test_1 = ball(5)
>	 ball_test_1.show_color()
>	 
>	 print
>	 ball_test_2 = ball(5, "red")
>	 ball_test_2.show_color()
>	 
>	 print
>	 ball_test_1.name = "John"
>	 print ball_test_1.name
>	 
>	 # test private element
>	 # will appear error when run below command
>	 #print ball_test_1.__vendor
>	 
>	 # ok when run below command, but could not write this code, we should write a
>	 # function to show ball's vendor
>	 print ball_test_1._ball__vendor
>	 
>	 # inherit test
>	 print
>	 class football(ball):
>		def run(self):
>			print "football is running"
>	 
>	 football_test_1 = football(10)
>	 football_test_1.run()
>	 
>	 # polymorphism test
>	 print
>	 def run(ball_t):
>		ball_t.run()
>		print "**** ****"
>	 run(ball_test_1)
>	 run(football_test_1)
>	 
>	 print
>	 print type(ball_test_1)
>	 print type(football_test_1)

* python中不需要在变量使用前先定义。
* 私有变量需要加__的前缀

NOTE:
1. raw_input()输入的变量是字符串的，要输入数字需要：int(raw_input())


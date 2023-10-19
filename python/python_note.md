python note
===========

v0.1 2015.5.20 Sherlock init part 1, 2
v0.2 2015.5.23 Sherlock init part 3
v0.3 2015.5.23 Sherlock init part4
v0.4 2015.5.31 Sherlock add part5

作用区域
-----------
```
#!/usr/bin/python

global y
y = 3

def func(x):
       x = 2
       print "x is", x

def func_1():
       global y # if delete this line, 'y' below is a local one
       y = 5
       print "y is", y

x = 10
func(x)
print "valuce of x is", x

func_1()
print "valuce of y is", y
```
函数内的x是local的，不改变x=10的值。在函数func_1内指示y是global的，函数内改变
y的值，函数外y=3变成y=5。

数据存储方式 
---------------
```
#!/usr/bin/python

x = 3
y = x

id_x = id(x)
id_y = id(y)
print "x id is", id_x
print "y id is", id_y

x = 5
id_x_new = id(x)
id_y_new = id(y)
print "x_new id is", id_x_new
print "y_new id is", id_y_new

# will appear error, as x has been deleted
#del(x)
#id_x_del = id(x)
#print "x_del id is", id_x_del

# will not appear error
#del(x)
#id(y)

x_list = ['a', 'b', 'c']
y_list = x_list
id_x_list = id(x_list)
id_y_list = id(y_list)
print "x_list id is", id_x_list
print "y_list id is", id_y_list

x_list.append("d_added")
print "new x_list is", x_list
id_new_x_list = id(x_list)
print "new x_list id is", id_new_x_list

y_list.append("y")
print "new y_list is", y_list
id_new_y_list = id(y_list)
print "new y_list id is", id_new_y_list
```
python中的数据都是类。python中的数据分为不可变变量和可变变量，其中数字，字符串
是不可变变量，其他的是可变变量。id(x)显示的是x变量的存储'地址'，根据id()可以了解
可变变量和不可变变量的性质。x的值不一样，id(x)的结果是不一样的，x是一个数字，是
不可变的，所以为x赋新值本质上是重新创建了一个变量，x_list是一个列表，是可变的，
所以改变x_list的值，就是改变它本身的值。y = x并没有新建了一个变量，而是为x变量
增加了一个叫y的索引，本质上是一个存储结构，所以id(x) = id(y); 所以改变x_list,
y_list也跟着变了。

典型数据结构
---------------

* 列表
```
#!/usr/bin/python

global shoplist
shoplist = ['apple', 'mango', 'carrot', 'banana']

def print_shoplist():
       print shoplist


lenth = shoplist.__len__()
print "len of shoplist is", lenth

shoplist.sort()
print_shoplist()

shoplist.append('pear')
print_shoplist()

shoplist.__delitem__(0)
print_shoplist()

print shoplist[0]
print shoplist[-1]

# use help() to check functions which list offered
# help(list)
```
列表是python的内置数据结构, 存放一组数据，列表里面的值是可以改变的。用help(list)
可以查看列表类中所包含的方法。上面列出几个方法：__len__返回列表的长度，sort对
列表的数据排序，append在列表的最后加入一个数据，__delitem__(x)删去索引是x的数据.
列表中数据的索引和c语言中数组的下标一样，但是可以逆向索引，如shoplist[-1]得到最
后一个元素的值。

* 元组
```
#!/usr/bin/python

zoo = ('wolf', 'elephant', 'penguin')
new_zoo = ('monkey', 'dolphin', zoo)

print "len of zoo is", len(zoo)
print "len of new zoo is", len(new_zoo)
print "2 of new zoo is", new_zoo[2]
print "[2][2] of new zoo is", new_zoo[2][2]

print "%s is %d years old" %('John', 12)

def func_return_multi():
       return 'John', 12

print func_return_multi()
```
元组也是python的内置数据结构，但是元组里的值是不可变的，当然如果元组里的元素是
一个列表，列表里的值是可以变的。元组的用途有很多，比如上面的格式话输出，当有多
个输出值时，它们的真值要用一个元组包含起来; python中的函数可以一次返回多个值，
返回的多个值被包含在一个元组中。

* 字符串
```
#!/usr/bin/python

string = "0123456789"
print "string is", string

new_string = string[0:5]
print "new_string is", new_string

print 'string 2 to end is', string[2:]
print 'string 1 to -1 is', string[1:-1]
print 'string start to end is', string[:]
print 'string start to end is', string[::4]

# list and tuple also have those kinds of operations
```
上面是字符串的切片操作，列表和元组也有相同的操作。

* 字典
```
#!/usr/bin/python

b = {
       'Swaroop': 'swaroopch@byteofpython.info',
       'Larry'  : 'larry@wall.org',
       'Matsumoto' : 'matz@ruby-lang.org',
       'Spammer'   : 'spammer@hotmail.com'
    }

print b['Larry']

# add a key->value in dictionary
b['Sherlock'] = "Sherlock@gmail.com"
print b

b.pop('Larry')
print b

if 'Larry' in b:
       print "Larry is in b"
else:
       print "Larry is not in b"
```
字典又一一对应的一组key->value组成，key需要是不可变变量。

* 集合
```
#!/usr/bin/python

s = set([1, 2, 3, 4])

print s

# add a key in set
s.add(10)
print s

s.remove(1)
print s

if 2 in s:
       print "2 is in s"
else:
       print "2 is not in s"
```
集合是一组值的集合，用一个列表初始化。集合中的元素也需要是不可变变量。

函数
-------
* 函数基础
```
#!/usr/bin/python

def test_add(a, b):
       return a + b

print "1 + 2 =", test_add(1, 2)

add_test = test_add
print "1 + 2 =", add_test(1, 2)

# need "pass" to fill this "none content function"
def nop():
       pass

# default input
def ball(r, color = "red", vendor = "A", llist = [1, 2, 3]):
       llist.append(4)
       print r
       print color
       print vendor
       print llist

print "test_1"
ball(5)

print "test_2"
ball(5, "blue")

print "test_3"
ball(5, vendor = "B")

print "test_4"
ball(5, llist = [4, 5, 6])
ball(5)

# variable input
print
print "variable input test"
def sum(*number):
       sum = 0
       for i in number:
       	sum = sum + i
       return sum
print "sum is", sum(1, 2, 3)

num = [1, 2, 3, 4]
print "sum is", sum(*num)

# key word input
print
print "key word input test"
def key_test(a, b, **c):
       print a
       print b
       print c
print  "key is", key_test(1, 2)
print
print  "key is", key_test(1, 2, name = "Sherlock")
print
dict_test = {"name" : "John", "age" : 12}
print  "key is", key_test(1, 2, **dict_test)
```
函数名是一个指向函数对象的引用，所以可以把一个函数名赋值给一个变量。函数的参数可以
是默认参数，可变参数，关键字参数等。当函数带默认参数时，默认参数需要是不可变参数。
不然就像上面代码中显示的那样，如果函数中改变这个参数的值，以后这个参数的值相应的
也都改变了。函数可以带可变参数, 可变参数可以直接传入函数，也可以先把所有参数组成
一个列表，再通过list传入。通过dictionary的方式可以传入一个字典。

面向对象
-----------
```
#!/usr/bin/python

class ball(object):
       def __init__(self, r, color = "green", vendor = "A"):
       	# init r, but we need not to declare r
       	self.r = r
       	self.color = color
       	# private element
       	self.__vendor = vendor
       	
       def run(self):
       	print "ball is running"
       def show_color(self):
       	print "color of ball is", self.color

# init an instance
ball_test_1 = ball(5)
ball_test_1.show_color()

print
ball_test_2 = ball(5, "red")
ball_test_2.show_color()

print
ball_test_1.name = "John"
print ball_test_1.name

# test private element
# will appear error when run below command
#print ball_test_1.__vendor

# ok when run below command, but could not write this code, we should write a
# function to show ball's vendor
print ball_test_1._ball__vendor

# inherit test
print
class football(ball):
       def run(self):
       	print "football is running"

football_test_1 = football(10)
football_test_1.run()

# polymorphism test
print
def run(ball_t):
       ball_t.run()
       print "**** ****"
run(ball_test_1)
run(football_test_1)

print
print type(ball_test_1)
print type(football_test_1)
```
python中不需要在变量使用前先定义。私有变量需要加"__"的前缀。注意: raw_input()输入
的变量是字符串的，要输入数字需要：int(raw_input())

异常
-------

标准库
---------

I/O
------

进程
-------

图形
--------

网络
--------

数据库
----------

web
-------

正则表达式
-----------

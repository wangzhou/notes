python note 1
=============

v0.1 2015.5.20 Sherlock init part 1, 2
v0.2 2015.5.23 Sherlock init part 3

1. 作用区域
-----------

>	 #!/usr/bin/python
>	 
>	 global y
>	 y = 3
>	 
>	 def func(x):
>		x = 2
>		print "x is", x
>	 
>	 def func_1():
>		global y # if delete this line, 'y' below is a local one
>		y = 5
>		print "y is", y
>	 
>	 x = 10
>	 func(x)
>	 print "valuce of x is", x
>	 
>	 func_1()
>	 pRint "valuce of y is", y

函数内的x是local的，不改变x=10的值。在函数func_1内指示y是global的，函数内改变
y的值，函数外y=3变成y=5。

2. 数据存储方式 
---------------

>	 #!/usr/bin/python
>	 
>	 x = 3
>	 y = x
>	 
>	 id_x = id(x)
>	 id_y = id(y)
>	 print "x id is", id_x
>	 print "y id is", id_y
>	 
>	 x = 5
>	 id_x_new = id(x)
>	 id_y_new = id(y)
>	 print "x_new id is", id_x_new
>	 print "y_new id is", id_y_new
>	 
>	 # will appear error, as x has been deleted
>	 #del(x)
>	 #id_x_del = id(x)
>	 #print "x_del id is", id_x_del
>	 
>	 # will not appear error
>	 #del(x)
>	 #id(y)
>	 
>	 x_list = ['a', 'b', 'c']
>	 y_list = x_list
>	 id_x_list = id(x_list)
>	 id_y_list = id(y_list)
>	 print "x_list id is", id_x_list
>	 print "y_list id is", id_y_list
>	 
>	 x_list.append("d_added")
>	 print "new x_list is", x_list
>	 id_new_x_list = id(x_list)
>	 print "new x_list id is", id_new_x_list
>	 
>	 y_list.append("y")
>	 print "new y_list is", y_list
>	 id_new_y_list = id(y_list)
>	 print "new y_list id is", id_new_y_list

python中的数据都是类。python中的数据分为不可变变量和可变变量，其中数字，字符串
是不可变变量，其他的是可变变量。id(x)显示的是x变量的存储'地址'，根据id()可以了解
可变变量和不可变变量的性质。x的值不一样，id(x)的结果是不一样的，x是一个数字，是
不可变的，所以为x赋新值本质上是重新创建了一个变量，x_list是一个列表，是可变的，
所以改变x_list的值，就是改变它本身的值。y = x并没有新建了一个变量，而是为x变量
增加了一个叫y的索引，本质上是一个存储结构，所以id(x) = id(y); 所以改变x_list,
y_list也跟着变了。

3. 典型数据结构
---------------
* 列表

>	 #!/usr/bin/python
>	 
>	 global shoplist
>	 shoplist = ['apple', 'mango', 'carrot', 'banana']
>	 
>	 def print_shoplist():
>		print shoplist
>	 
>	 
>	 lenth = shoplist.__len__()
>	 print "len of shoplist is", lenth
>	 
>	 shoplist.sort()
>	 print_shoplist()
>	 
>	 shoplist.append('pear')
>	 print_shoplist()
>	 
>	 shoplist.__delitem__(0)
>	 print_shoplist()
>	 
>	 print shoplist[0]
>	 print shoplist[-1]
>	 
>	 # use help() to check functions which list offered
>	 #help(list)

列表是python的内置数据结构, 存放一组数据，列表里面的值是可以改变的。用help(list)
可以查看列表类中所包含的方法。上面列出几个方法：__len__返回列表的长度，sort对
列表的数据排序，append在列表的最后加入一个数据，__delitem__(x)删去索引是x的数据.
列表中数据的索引和c语言中数组的下标一样，但是可以逆向索引，如shoplist[-1]得到最
后一个元素的值。

* 元组

>	 #!/usr/bin/python
>	 
>	 zoo = ('wolf', 'elephant', 'penguin')
>	 new_zoo = ('monkey', 'dolphin', zoo)
>	 
>	 print "len of zoo is", len(zoo)
>	 print "len of new zoo is", len(new_zoo)
>	 print "2 of new zoo is", new_zoo[2]
>	 print "[2][2] of new zoo is", new_zoo[2][2]
>	 
>	 print "%s is %d years old" %('John', 12)
>	 
>	 def func_return_multi():
>		return 'John', 12
>	 
>	 print func_return_multi()

元组也是python的内置数据结构，但是元组里的值是不可变的，当然如果元组里的元素是
一个列表，列表里的值是可以变的。元组的用途有很多，比如上面的格式话输出，当有多
个输出值时，它们的真值要用一个元组包含起来; python中的函数可以一次返回多个值，
返回的多个值被包含在一个元组中。

* 字符串

>	 #!/usr/bin/python
>	 
>	 string = "0123456789"
>	 print "string is", string
>	 
>	 new_string = string[0:5]
>	 print "new_string is", new_string
>	 
>	 print 'string 2 to end is', string[2:]
>	 print 'string 1 to -1 is', string[1:-1]
>	 print 'string start to end is', string[:]
>	 print 'string start to end is', string[::4]
>	 
>	 # list and tuple also have those kinds of operations

上面是字符串的切片操作，列表和元组也有相同的操作。

* 字典

>	 #!/usr/bin/python
>	 
>	 b = {
>		'Swaroop': 'swaroopch@byteofpython.info',
>		'Larry'  : 'larry@wall.org',
>		'Matsumoto' : 'matz@ruby-lang.org',
>		'Spammer'   : 'spammer@hotmail.com'
>	     }
>	 
>	 print b['Larry']
>	 
>	 # add a key->value in dictionary
>	 b['Sherlock'] = "Sherlock@gmail.com"
>	 print b
>	 
>	 b.pop('Larry')
>	 print b
>	 
>	 if 'Larry' in b:
>		print "Larry is in b"
>	 else:
>		print "Larry is not in b"

字典又一一对应的一组key->value组成，key需要是不可变变量。

* 集合

>	 #!/usr/bin/python
>	 
>	 s = set([1, 2, 3, 4])
>	 
>	 print s
>	 
>	 # add a key in set
>	 s.add(10)
>	 print s
>	 
>	 s.remove(1)
>	 print s
>	 
>	 if 2 in s:
>		print "2 is in s"
>	 else:
>		print "2 is not in s"

集合是一组值的集合，用一个列表初始化。集合中的元素也需要是不可变变量。

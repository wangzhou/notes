
1. kvm dirty log

2. mincore systemcall   记录va是否有pa，标脏借用，mmap磁盘页，写的时候一定创建物理内存了。swap下不能用。

3. userspace fault

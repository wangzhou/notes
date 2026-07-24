



但是因为VNCR的缘故还是需要
trap到L0处理。vEL2作为host的时候(姑且叫做vhost)，vEL2自己的VNCR配置成vhost的VA，
而硬件实际工作的时候用的物理VNCR(EL2)的配置，这就需要vhost VNCR配置的VA通过IPA、
PA得到EL2的fixmap VA，在EL2的S1里建立fixmap VA -> PA的映射。这样，VNCR也有了一个
shadow关系，vEL2 host页表变化的时候，也得通过随后的TLBI trap到L0里修正相关的页表
和TLB信息。

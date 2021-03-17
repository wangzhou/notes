int g;

struct e {
	int a;
	int b;
	int c;
};

struct f {
	int a;
	int b;
	int c;
};

int callee2(int d)
{
	return d + 5;
}

int callee(int a, int *b, int *c)
{
	int sum;	

	sum = a + *b;
	*c = sum;

	return callee2(sum);
}

int callee3(struct e *e)
{
	return (e->a + e->b + e->c);
}

int callee4(struct f f)
{
	return (f.a + f.b + f.c);
}

void caller(void)
{
	int a = 1;
	int b = 2;
	int c;
	int sum = 0;
	int sum_3 = 0;
	int sum_4 = 0;

	struct e e = { .a = 4, .b = 5, .c = 6};
	struct f f = { .a = 4, .b = 5, .c = 6};

	sum = callee(a, &b, &c);
	sum_3 = callee3(&e);
	sum_4 = callee4(f);
}

void call_0(void)
{
	caller();
}

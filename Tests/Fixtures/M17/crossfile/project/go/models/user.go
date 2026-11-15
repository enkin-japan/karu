package models

type User struct {
	Name string
	age  int
}

func (u *User) Greet(other string) string {
	return "hi " + other
}

func (u *User) secret() int { return u.age }

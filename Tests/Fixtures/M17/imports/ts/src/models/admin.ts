import { User } from "./index";

export class Admin extends User {
  ban(user: User): boolean {
    return user.name.length > 0;
  }
}

package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

func cmdGroup(db *DB, a args, js bool) error {
	if len(a.pos) < 1 {
		return fmt.Errorf("usage: wa group list|info|create|rename|topic|add|remove|promote|demote|leave|refresh|invite-link ...")
	}
	sub, rest := a.pos[0], a.pos[1:]
	switch sub {
	case "list":
		rows, err := db.Query(`SELECT jid,COALESCE(name,''),COALESCE(topic,''),participants FROM groups ORDER BY name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		type g struct {
			JID, Name, Topic string
			Members          int
		}
		var out []g
		for rows.Next() {
			var x g
			var p string
			rows.Scan(&x.JID, &x.Name, &x.Topic, &p)
			var ps []gpart
			json.Unmarshal([]byte(p), &ps)
			x.Members = len(ps)
			out = append(out, x)
		}
		emit(js, out, func() {
			if len(out) == 0 {
				fmt.Println("(no groups cached; the daemon fills this, or run: wa group refresh)")
			}
			for _, x := range out {
				fmt.Printf("%s  (%d members)  <%s>\n", x.Name, x.Members, x.JID)
			}
		})
		return nil
	case "refresh":
		_, err := rpc(map[string]any{"cmd": "refresh_groups"})
		if err == nil {
			fmt.Println("refreshed")
		}
		return err
	case "invite-link":
		if len(rest) < 1 {
			return fmt.Errorf("usage: wa group invite-link <group>")
		}
		jid, err := db.resolve(rest[0])
		if err != nil {
			return err
		}
		res, err := rpc(map[string]any{"cmd": "invite_link", "chat": jid})
		if err != nil {
			return err
		}
		fmt.Println(res["link"])
		return nil
	case "create":
		if len(rest) < 2 {
			return fmt.Errorf("usage: wa group create <name> <member>...")
		}
		members, err := resolveAll(db, rest[1:])
		if err != nil {
			return err
		}
		_, err = db.addOutbox("group_create", fmt.Sprintf("create group %q with %s", rest[0], describeAll(db, members)),
			map[string]any{"name": rest[0], "members": members})
		return err
	}
	// everything below takes <group> first
	if len(rest) < 1 {
		return fmt.Errorf("usage: wa group %s <group> ...", sub)
	}
	gjid, err := db.resolve(rest[0])
	if err != nil {
		return err
	}
	gname := fmt.Sprintf("%s <%s>", db.displayName(gjid), gjid)
	switch sub {
	case "info":
		var name, topic, owner, p string
		var created int64
		if err := db.QueryRow(`SELECT COALESCE(name,''),COALESCE(topic,''),COALESCE(owner,''),created,participants FROM groups WHERE jid=?`, gjid).
			Scan(&name, &topic, &owner, &created, &p); err != nil {
			return fmt.Errorf("group %s not cached (run: wa group refresh)", gjid)
		}
		var ps []gpart
		json.Unmarshal([]byte(p), &ps)
		for i := range ps {
			ps[i].Name = db.displayName(firstNonEmpty(ps[i].PN, ps[i].JID))
		}
		info := map[string]any{"jid": gjid, "name": name, "topic": topic, "owner": owner, "created": tsStr(created), "participants": ps}
		emit(js, info, func() {
			fmt.Printf("%s <%s>\ncreated %s  owner %s\ntopic: %s\n", name, gjid, tsStr(created), db.displayName(owner), topic)
			for _, x := range ps {
				role := ""
				if x.Admin {
					role = " (admin)"
				}
				fmt.Printf("  %s%s <%s>\n", x.Name, role, x.JID)
			}
		})
		return nil
	case "rename":
		if len(rest) < 2 {
			return fmt.Errorf("usage: wa group rename <group> <name>")
		}
		name := strings.Join(rest[1:], " ")
		if len([]rune(name)) > 25 {
			return fmt.Errorf("group names are limited to 25 characters")
		}
		_, err = db.addOutbox("group_rename", fmt.Sprintf("rename group %s to %q", gname, name), map[string]any{"group": gjid, "name": name})
	case "topic":
		if len(rest) < 2 {
			return fmt.Errorf("usage: wa group topic <group> <text...>")
		}
		topic := strings.Join(rest[1:], " ")
		_, err = db.addOutbox("group_topic", fmt.Sprintf("set topic of %s to %q", gname, topic), map[string]any{"group": gjid, "topic": topic})
	case "add", "remove", "promote", "demote":
		if len(rest) < 2 {
			return fmt.Errorf("usage: wa group %s <group> <member>...", sub)
		}
		members, err2 := resolveAll(db, rest[1:])
		if err2 != nil {
			return err2
		}
		_, err = db.addOutbox("group_"+sub, fmt.Sprintf("%s %s in %s", sub, describeAll(db, members), gname), map[string]any{"group": gjid, "members": members})
	case "leave":
		_, err = db.addOutbox("group_leave", "LEAVE group "+gname, map[string]any{"group": gjid})
	default:
		return fmt.Errorf("unknown group command %q", sub)
	}
	return err
}

type gpart struct {
	JID   string `json:"jid"`
	PN    string `json:"pn,omitempty"`
	Admin bool   `json:"admin"`
	Name  string `json:"name,omitempty"`
}

func resolveAll(db *DB, names []string) ([]string, error) {
	var out []string
	for _, n := range names {
		j, err := db.resolve(n)
		if err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, nil
}

func describeAll(db *DB, jids []string) string {
	var s []string
	for _, j := range jids {
		s = append(s, fmt.Sprintf("%s <%s>", db.displayName(j), j))
	}
	return strings.Join(s, ", ")
}

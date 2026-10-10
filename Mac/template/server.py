"""__APP_NAME__'s data API. The app and Hermes both use these tools: the app
through Hermex, Hermes over MCP as __TOOL_PREFIX___<tool>.

Rules (see the hermex-app-factory skill):
- The first argument is the app's SQLite connection; the rest are JSON
  arguments described by type hints and the docstring's Args section.
- Return plain JSON: dicts, lists, strings, numbers, booleans. SQLite stores
  booleans as 0/1, so convert with bool() before returning.
- Mark tools that change data with changes=True. Return the ids you changed
  under "highlight" so the open app outlines them.
"""

import uuid

from hermex_apps import API

api = API()


@api.setup
def setup(db):
    db.execute(
        "create table if not exists items ("
        " id text primary key,"
        " title text not null,"
        " done integer not null default 0,"
        " created_at text not null default (datetime('now')))"
    )


def _item(row):
    return {"id": row["id"], "title": row["title"], "done": bool(row["done"]), "created_at": row["created_at"]}


@api.tool
def items(db) -> list:
    """Every item, oldest first."""
    return [_item(r) for r in db.execute("select * from items order by created_at, rowid")]


@api.tool(changes=True, route="home")
def add_item(db, title: str) -> dict:
    """Add an item.

    Args:
        title: What the item says.
    """
    title = title.strip()
    if not title:
        raise ValueError("The item needs a title.")
    item_id = uuid.uuid4().hex[:8]
    db.execute("insert into items (id, title) values (?, ?)", (item_id, title))
    return {"id": item_id, "highlight": [item_id]}


@api.tool(changes=True)
def set_done(db, id: str, done: bool = True) -> dict:
    """Mark an item done or not done.

    Args:
        id: The item's id.
        done: True to mark it done.
    """
    if db.execute("update items set done = ? where id = ?", (int(done), id)).rowcount == 0:
        raise ValueError(f"No item {id}.")
    return {"id": id, "done": done, "highlight": [id]}

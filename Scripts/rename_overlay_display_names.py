#!/usr/bin/env python3
import argparse
import json
import sqlite3
import sys
import time
import urllib.parse
import urllib.request


NOMINATIM_URL = "https://nominatim.openstreetmap.org/reverse"
DEFAULT_USER_AGENT = "SnapToMap rename-overlay-display-names/1.0"
FALLBACK_DISPLAY_NAME = "Untitled overlay"


def normalized_name(value):
    if not value:
        return None
    value = str(value).strip()
    if not value or value == FALLBACK_DISPLAY_NAME:
        return None
    return value


def georect(corners):
    lats = [float(c["latitude"]) for c in corners]
    lons = [float(c["longitude"]) for c in corners]
    return {
        "min_lat": min(lats),
        "max_lat": max(lats),
        "min_lon": min(lons),
        "max_lon": max(lons),
    }


def nominatim_zoom(rect):
    span = max(abs(rect["max_lat"] - rect["min_lat"]), abs(rect["max_lon"] - rect["min_lon"]))
    if span < 0.002:
        return 18
    if span < 0.005:
        return 17
    if span < 0.01:
        return 16
    if span < 0.025:
        return 15
    if span < 0.05:
        return 14
    if span < 0.1:
        return 13
    if span < 0.25:
        return 12
    if span < 0.5:
        return 11
    if span < 1:
        return 10
    if span < 2:
        return 9
    if span < 4:
        return 8
    if span < 8:
        return 7
    if span < 16:
        return 6
    if span < 32:
        return 5
    return 4


def preferred_name(payload, zoom):
    address = payload.get("address") or {}
    if zoom >= 15:
        keys = ["road", "neighbourhood", "suburb", "city_district", "quarter", "city", "town", "village"]
    elif zoom >= 11:
        keys = ["suburb", "city_district", "quarter", "neighbourhood", "city", "town", "village", "municipality"]
    else:
        keys = ["city", "town", "village", "municipality", "county", "state", "country"]

    candidates = [address.get(key) for key in keys]
    namedetails = payload.get("namedetails") or {}
    display_name = payload.get("display_name")
    first_display_part = display_name.split(",", 1)[0] if display_name else None
    candidates.extend([namedetails.get("name"), payload.get("name"), first_display_part])
    for candidate in candidates:
        name = normalized_name(candidate)
        if name:
            return name
    return None


def nominatim_name(corners, user_agent, accept_language):
    rect = georect(corners)
    primary_zoom = nominatim_zoom(rect)
    for zoom in reverse_zoom_sequence(primary_zoom):
        name = request_nominatim_name(rect, zoom, user_agent, accept_language)
        if name:
            return name
    return None


def reverse_zoom_sequence(primary_zoom):
    seen = set()
    sequence = [primary_zoom, 14, 12, 10, 8, 6, 4]
    for zoom in sequence:
        if zoom in seen or zoom > primary_zoom or zoom < 3 or zoom > 18:
            continue
        seen.add(zoom)
        yield zoom


def request_nominatim_name(rect, zoom, user_agent, accept_language):
    params = {
        "format": "jsonv2",
        "lat": f"{(rect['min_lat'] + rect['max_lat']) / 2:.7f}",
        "lon": f"{(rect['min_lon'] + rect['max_lon']) / 2:.7f}",
        "zoom": str(zoom),
        "addressdetails": "1",
        "namedetails": "1",
    }
    url = f"{NOMINATIM_URL}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": user_agent,
            "Accept-Language": accept_language,
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return preferred_name(payload, zoom)


def find_overlay_table(connection):
    tables = [
        row[0]
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    ]
    for table in tables:
        cols = connection.execute(f'PRAGMA table_info("{table}")').fetchall()
        by_upper = {row[1].upper(): row[1] for row in cols}
        required = {"Z_PK", "ZCORNERSJSON", "ZDISPLAYNAME"}
        if required.issubset(by_upper):
            return table, by_upper
    raise RuntimeError("Could not find a Core Data overlay table with ZCORNERSJSON and ZDISPLAYNAME.")


def load_rows(connection, table, cols, overwrite):
    pk = cols["Z_PK"]
    corners = cols["ZCORNERSJSON"]
    display_name = cols["ZDISPLAYNAME"]
    query = f'SELECT "{pk}", "{corners}", "{display_name}" FROM "{table}" ORDER BY "{pk}"'
    rows = connection.execute(query).fetchall()
    if overwrite:
        return rows
    return [row for row in rows if not normalized_name(row[2])]


def parse_corners(raw_json):
    corners = json.loads(raw_json or "[]")
    if not isinstance(corners, list) or len(corners) != 4:
        raise ValueError("expected four corners")
    return corners


def main():
    parser = argparse.ArgumentParser(description="Rename SnapToMap overlay rows with OSM Nominatim reverse geocoding.")
    parser.add_argument("sqlite_path", help="Path to the SnapToMapModel.sqlite store.")
    parser.add_argument("--dry-run", action="store_true", help="Print proposed names without writing.")
    parser.add_argument("--overwrite", action="store_true", help="Rename rows that already have displayName values.")
    parser.add_argument("--user-agent", default=DEFAULT_USER_AGENT, help="Nominatim User-Agent header.")
    parser.add_argument("--accept-language", default="en", help="Nominatim Accept-Language header.")
    args = parser.parse_args()

    connection = sqlite3.connect(args.sqlite_path)
    table, cols = find_overlay_table(connection)
    rows = load_rows(connection, table, cols, args.overwrite)
    if not rows:
        print("No overlay rows need naming.")
        return 0

    pk_col = cols["Z_PK"]
    display_col = cols["ZDISPLAYNAME"]
    last_request_at = None
    updated = 0

    print(f"Naming {len(rows)} overlay row(s) from {table}.")
    for row_pk, corners_json, old_name in rows:
        try:
            corners = parse_corners(corners_json)
        except Exception as exc:
            print(f"skip row {row_pk}: invalid corners ({exc})", file=sys.stderr)
            continue

        if last_request_at is not None:
            wait = max(0, 1.0 - (time.time() - last_request_at))
            if wait:
                time.sleep(wait)
        last_request_at = time.time()

        try:
            name = nominatim_name(corners, args.user_agent, args.accept_language)
        except Exception as exc:
            print(f"skip row {row_pk}: Nominatim request failed ({exc})", file=sys.stderr)
            continue

        name = normalized_name(name)
        if not name:
            print(f"skip row {row_pk}: Nominatim returned no usable name", file=sys.stderr)
            continue

        if args.dry_run:
            print(f"row {row_pk}: {old_name!r} -> {name!r}")
        else:
            connection.execute(
                f'UPDATE "{table}" SET "{display_col}" = ? WHERE "{pk_col}" = ?',
                (name, row_pk),
            )
            connection.commit()
            print(f"row {row_pk}: {old_name!r} -> {name!r}")
        updated += 1

    action = "would update" if args.dry_run else "updated"
    print(f"{action} {updated} row(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

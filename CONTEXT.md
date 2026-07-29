# Phrover

Phrover is a rover that interprets human missions, perceives its surroundings, and navigates safely through local spaces.

## Language

**Room-mapping session**:
A bounded period in which the rover maintains one local topology of rooms and their connections.
_Avoid_: Map session, topology lifetime

**Room**:
A locally distinct spatial region that the rover can occupy.
_Avoid_: Area, zone

**Doorway candidate**:
An observed opening that may connect the current room to another room.
_Avoid_: Frontier, possible door

**Doorway**:
A confirmed traversable connection between two rooms.
_Avoid_: Opening, passage candidate

**Room transition**:
A confirmed traversal through a doorway from one room to another.
_Avoid_: Room change, doorway visit

**Current room**:
The room the rover presently occupies.
_Avoid_: Active room

**Room-transition mission**:
A mission whose destination is another room rather than an object or named location.
_Avoid_: Exploration mission, go-to-room command

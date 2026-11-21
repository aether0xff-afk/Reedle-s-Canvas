"""Reference labels and PNG crops for AET-50 and AET-44."""

import base64
from fractions import Fraction
from functools import partial
import json
from math import isqrt
from pathlib import Path
from typing import Annotated, Literal, Self
from uuid import UUID

from pydantic import Field, model_validator

from server.reedle_server.contract import CropEntity, MAX_ENTITIES, MAX_PNG_BYTES, StrictObject, verified_png

from .sketches import Box, Sketch, circuit, equation, forces, graph, lewis, reflection, render


Subject = Literal["math", "chemistry", "physics"]
Status = Literal["correct", "partial", "error"]
Source = Literal["synthetic", "anonymized-handwriting"]
Phrase = Annotated[str, Field(min_length=1, max_length=512)]
Phrases = Annotated[tuple[Phrase, ...], Field(min_length=1)]


class Annotation(StrictObject):
    id: Annotated[str, Field(pattern=r"^[a-z][a-z0-9-]{0,63}$")]
    subject: Subject
    status: Status
    category: Annotated[str, Field(pattern=r"^[a-z][a-z0-9-]{0,63}$")]
    answers: Phrases
    transcripts: Phrases
    structure: Annotated[tuple[Phrases, ...], Field(min_length=1)]
    targets: Annotated[tuple[Annotated[int, Field(ge=0)], ...], Field(min_length=1)]

    @property
    def answer(self) -> str:
        return self.answers[0]

    @property
    def intervene(self) -> bool:
        return self.status == "error"


class ManifestCase(Annotation):
    image: Annotated[str, Field(min_length=1)]
    boxes: Annotated[tuple[Box, ...], Field(min_length=1, max_length=MAX_ENTITIES)]

    @model_validator(mode="after")
    def validate_boxes(self) -> Self:
        if any(index >= len(self.boxes) for index in self.targets) or len(set(self.targets)) != len(self.targets):
            raise ValueError("invalid target index or duplicate targets")
        for index, (x, y, width, height) in enumerate(self.boxes):
            CropEntity(id=str(UUID(int=index)), x=x, y=y, width=width, height=height)
        return self


class Manifest(StrictObject):
    schemaVersion: Literal[1]
    source: Source
    cases: Annotated[tuple[ManifestCase, ...], Field(min_length=1)]


class Case(Annotation):
    source: Source = "synthetic"
    sketch: Sketch | None = None
    image_path: Path | None = None
    boxes: tuple[Box, ...] = ()

    def crop(self) -> tuple[bytes, tuple[Box, ...]]:
        if self.sketch is not None:
            return render(self.sketch, self.id)
        assert self.image_path is not None
        with self.image_path.open("rb") as handle:
            png = handle.read(MAX_PNG_BYTES + 1)
        try:
            verified_png(base64.b64encode(png).decode("ascii"))
        except ValueError:
            raise ValueError(f"{self.id} must use a valid PNG within the gateway image limits") from None
        return png, self.boxes


def load_manifest(path: Path) -> tuple[Case, ...]:
    manifest = Manifest.model_validate_json(path.read_bytes())
    if len({item.id for item in manifest.cases}) != len(manifest.cases):
        raise ValueError("manifest contains duplicate case IDs")
    root = path.resolve().parent
    cases = []
    for item in manifest.cases:
        image_path = (root / item.image).resolve()
        if not image_path.is_relative_to(root):
            raise ValueError(f"{item.id} has an image outside the manifest directory")
        case = Case(**item.model_dump(exclude={"image"}), image_path=image_path, source=manifest.source)
        case.crop()
        cases.append(case)
    return tuple(cases)


def write_manifest(directory: Path, cases: tuple[Case, ...]) -> Path:
    if not cases or len({case.source for case in cases}) != 1:
        raise ValueError("export requires one dataset source")
    directory.mkdir(parents=True, exist_ok=True)
    entries = []
    for case in cases:
        png, boxes = case.crop()
        name = f"{case.id}.png"
        (directory / name).write_bytes(png)
        labels = case.model_dump(exclude={"source", "sketch", "image_path", "boxes"})
        entries.append(ManifestCase(image=name, boxes=boxes, **labels))
    manifest = Manifest(schemaVersion=1, source=cases[0].source, cases=tuple(entries))
    output = directory / "manifest.json"
    output.write_text(json.dumps(manifest.model_dump(mode="json"), ensure_ascii=False, indent=2) + "\n",
                      encoding="utf-8")
    return output


def _math(index: int, status: Status, category: str, context: str, work: str, answer: str) -> Case:
    aliases = (work, f"{context}: {work}")
    answer_aliases = tuple(dict.fromkeys((answer, answer.replace(" ", ""))))
    return Case(id=f"math-{index:02}", subject="math", status=status, category=category,
                answers=answer_aliases, transcripts=aliases, structure=((work,),), targets=(1,),
                sketch=equation(context, work))


def _calculation(index: int, context: str, expression: str, written: str, expected: int | Fraction,
                 category: str = "arithmetic") -> Case:
    # Only audited, authored fixture values enter Fraction. Transcribed expressions are scored as text.
    correct = Fraction(written) == expected
    answer = written if correct else str(expected)
    return _math(index, "correct" if correct else "error", "correct" if correct else category,
                 context, f"{expression} = {written}", answer)


def _math_cases() -> tuple[Case, ...]:
    return (
        _calculation(1, "Compute the sum", "2 + 2", "4", 2 + 2),
        _calculation(2, "Compute the sum", "2 + 2", "5", 2 + 2),
        _calculation(3, "Multiply", "6 * 7", "42", 6 * 7),
        _math(4, "partial", "incomplete", "Evaluate the product", "3(4 + 2) = 3 * 6", str(3 * (4 + 2))),
        _calculation(5, "Use order of operations", "3 + 4 * 2", "14", 3 + 4 * 2, "order-of-operations"),
        _calculation(6, "Add the fractions", "1/2 + 1/3", "5/6", Fraction(1, 2) + Fraction(1, 3)),
        _calculation(7, "Add the fractions", "1/2 + 1/3", "2/5", Fraction(1, 2) + Fraction(1, 3), "fraction"),
        _calculation(8, "Divide", "12 / 3", "4", Fraction(12, 3)),
        _calculation(9, "Subtract", "3 - 8", "5", 3 - 8, "sign"),
        _calculation(10, "Evaluate the power", "2^3", "6", 2**3, "exponent"),
        _calculation(11, "Find the square root", "sqrt(49)", "7", isqrt(49)),
        _math(12, "partial", "incomplete", "Solve 3x + 2 = 14", "3x = 12", f"x = {Fraction(14 - 2, 3)}"),
        _math(13, "error", "linear-equation", "Solve 2x - 1 = 7", "x = 3", f"x = {Fraction(7 + 1, 2)}"),
        _math(14, "correct", "correct", "Solve 4x + 1 = 9", "x = 2", f"x = {Fraction(9 - 1, 4)}"),
        _math(15, "error", "expansion", "Expand (x + 2)^2", "x^2 + 4", "x^2 + 4x + 4"),
        _math(16, "correct", "correct", "Factor x^2 + 5x + 6", "(x + 2)(x + 3)", "(x + 2)(x + 3)"),
        _math(17, "error", "inequality", "Solve -2x > 6", "x > -3", f"x < {Fraction(6, -2)}"),
        _math(18, "partial", "incomplete", "Solve x^2 = 9", "x = 3", f"x = ±{isqrt(9)}"),
        _calculation(19, "Add the decimals", "0.2 + 0.3", "0.5", Fraction("0.2") + Fraction("0.3")),
        _math(20, "partial", "incomplete", "Solve x/2 + 1 = 5", "x/2 = 4", f"x = {(5 - 1) * 2}"),
    )


def _diagram(subject: Subject, index: int, status: Status, category: str, answers: Phrases,
             sketch: Sketch, *parts: Phrases) -> Case:
    versions = tuple("; ".join(group[version] for group in parts) for version in (0, -1))
    return Case(id=f"{subject}-{index:02}", subject=subject, status=status, category=category,
                answers=answers, transcripts=tuple(dict.fromkeys(versions)),
                structure=parts, targets=(1,), sketch=sketch)


def _chemistry_cases() -> tuple[Case, ...]:
    hydrogen = ("H", 1, 0)
    water = ("H-O-H with 2 lone pairs on O", "2 O-H single bonds and 2 oxygen lone pairs")
    oxygen = ("O=O with 2 lone pairs per O", "O2 with a double bond and 2 lone pairs per oxygen")
    nitrogen = ("N≡N with 1 lone pair per N", "N2 with a triple bond and 1 lone pair per nitrogen")
    methane = ("4 C-H single bonds", "4 single bonds between carbon and hydrogen")
    ammonia = ("3 N-H single bonds and 1 lone pair on N", "3 single bonds and 1 nitrogen lone pair")
    carbon_dioxide = ("O=C=O with 2 lone pairs per O", "2 C=O double bonds and 2 lone pairs per oxygen")
    hydrogen_fluoride = ("H-F with 3 lone pairs on F", "1 H-F single bond and 3 fluorine lone pairs")
    fluoride = ("[F]- with 4 lone pairs", "negative fluorine ion with 4 lone pairs")
    ammonium = ("[NH4]+ with 4 N-H single bonds", "positive ammonium ion with 4 single bonds")
    make = partial(_diagram, "chemistry")
    return (
        make(1, "correct", "correct", water, lewis("H2O", "O", 2, (hydrogen,) * 2),
             ("H-O-H", "2 single O-H bonds"), ("2 lone pairs on O", "oxygen has 2 lone pairs")),
        make(2, "error", "lone-pair", water, lewis("H2O", "O", 1, (hydrogen,) * 2),
             ("H-O-H", "2 single O-H bonds"), ("1 lone pair on O", "oxygen has 1 lone pair")),
        make(3, "correct", "correct", oxygen, lewis("O2", "O", 2, (("O", 2, 2),)),
             ("O=O", "O-O double bond"), ("2 lone pairs per O", "2 lone pairs on each O")),
        make(4, "error", "bond-order", oxygen, lewis("O2", "O", 3, (("O", 1, 3),)),
             ("O-O", "O-O single bond"), ("3 lone pairs per O", "3 lone pairs on each O")),
        make(5, "correct", "correct", nitrogen, lewis("N2", "N", 1, (("N", 3, 1),)),
             ("N≡N", "N-N triple bond"), ("1 lone pair per N", "1 lone pair on each N")),
        make(6, "error", "bond-order", nitrogen, lewis("N2", "N", 1, (("N", 2, 1),)),
             ("N=N", "N-N double bond"), ("1 lone pair per N", "1 lone pair on each N")),
        make(7, "correct", "correct", methane, lewis("CH4", "C", 0, (hydrogen,) * 4),
             ("4 C-H single bonds", "carbon with 4 single bonds to H")),
        make(8, "partial", "incomplete", methane, lewis("Start CH4", "C", 0, (hydrogen,) * 3),
             ("3 C-H single bonds", "carbon with 3 single bonds to H")),
        make(9, "correct", "correct", ammonia, lewis("NH3", "N", 1, (hydrogen,) * 3),
             ("3 N-H single bonds", "nitrogen with 3 single bonds to H"), ("1 lone pair on N", "nitrogen has 1 lone pair")),
        make(10, "error", "lone-pair", ammonia, lewis("NH3", "N", 0, (hydrogen,) * 3),
             ("3 N-H single bonds", "nitrogen with 3 single bonds to H"), ("no lone pair on N", "0 lone pairs on N")),
        make(11, "correct", "correct", carbon_dioxide, lewis("CO2", "C", 0, (("O", 2, 2),) * 2),
             ("O=C=O", "2 C=O double bonds"), ("2 lone pairs per O", "2 lone pairs on each O")),
        make(12, "partial", "incomplete", carbon_dioxide, lewis("Start CO2", "C", 0, (("O", 2, 2),)),
             ("one C=O double bond", "one O double bonded to C"), ("2 lone pairs on O", "oxygen has 2 lone pairs")),
        make(13, "correct", "correct", hydrogen_fluoride, lewis("HF", "H", 0, (("F", 1, 3),)),
             ("H-F single bond", "single H-F bond"), ("3 lone pairs on F", "fluorine has 3 lone pairs")),
        make(14, "error", "bond-order", hydrogen_fluoride, lewis("HF", "H", 0, (("F", 2, 2),)),
             ("H=F", "H-F double bond"), ("2 lone pairs on F", "fluorine has 2 lone pairs")),
        make(15, "correct", "correct", fluoride, lewis("F- ion", "F", 4, (), charge="-"),
             ("[F]-", "negative F ion"), ("4 lone pairs", "4 pairs of dots")),
        make(16, "error", "charge", fluoride, lewis("F- ion", "F", 4, ()),
             ("F has no marked charge", "F with no charge shown"), ("4 lone pairs", "4 pairs of dots")),
        make(17, "correct", "correct", ammonium, lewis("NH4+ ion", "N", 0, (hydrogen,) * 4, charge="+"),
             ("[NH4]+", "positive ammonium ion"), ("4 N-H single bonds", "4 single N-H bonds")),
        make(18, "partial", "incomplete", ammonium, lewis("Start NH4+", "N", 0, (hydrogen,) * 3, charge="+"),
             ("positive charge", "+ charge"), ("3 N-H single bonds", "3 single N-H bonds")),
        make(19, "partial", "incomplete", ("Cl-Cl with 3 lone pairs per Cl", "Cl2 with a single bond and 3 pairs per Cl"),
             lewis("Start Cl2", "Cl", 0, (("Cl", 1, 0),)),
             ("Cl-Cl single bond", "single Cl-Cl bond"), ("no lone pairs shown", "0 lone pairs shown")),
        make(20, "error", "bond-order", ("H-H single bond", "one single bond between H atoms"),
             lewis("H2", "H", 0, (("H", 2, 0),)), ("H=H", "H-H double bond")),
    )


def _physics_cases() -> tuple[Case, ...]:
    rest = ("normal force up and weight down", "N up and W down")
    fall = ("weight points down", "W down")
    level = ("positive horizontal line on v-t axes", "constant positive velocity")
    accelerate = ("rising straight line on v-t axes", "velocity increases linearly with time")
    lamp_on = ("battery and bulb connected by a closed switch", "complete series circuit with the switch closed")
    lamp_off = ("battery and bulb connected by an open switch", "series circuit interrupted at the open switch")
    mirror = ("30 degree incident and reflected angles", "both rays make 30 degrees with the normal")
    make = partial(_diagram, "physics")
    return (
        make(1, "correct", "correct", rest, forces("Book at rest on a table", ("up", "N"), ("down", "W")),
             ("N up", "normal force up"), ("W down", "weight down")),
        make(2, "error", "force-direction", rest, forces("Book at rest on a table", ("down", "N"), ("up", "W")),
             ("N down", "normal force down"), ("W up", "weight up")),
        make(3, "correct", "correct", ("equal opposing horizontal forces", "equal left and right arrows"),
             forces("Balanced horizontal forces", ("left", "F"), ("right", "F")),
             ("equal opposing horizontal forces", "equal left and right arrows")),
        make(4, "error", "friction-direction", ("friction left", "Ff points opposite the slide"),
             forces("Friction on cart sliding right", ("right", "Ff")), ("Ff right", "friction points right")),
        make(5, "correct", "correct", fall, forces("Free fall without drag", ("down", "W")),
             ("W down", "weight points down")),
        make(6, "error", "force-direction", fall, forces("Free fall without drag", ("up", "W")),
             ("W up", "weight points up")),
        make(7, "partial", "incomplete", rest, forces("Start: book at rest", ("up", "N")),
             ("N up", "normal force up"), ("only one arrow", "weight arrow absent")),
        make(8, "correct", "correct", ("drag up and weight down with equal magnitude", "D up and W down, equal lengths"),
             forces("Falling at terminal speed", ("up", "D"), ("down", "W")),
             ("D up", "drag up"), ("W down", "weight down"), ("equal lengths", "equal magnitude")),
        make(9, "correct", "correct", level, graph("Constant positive velocity", "level"),
             ("v-t axes", "velocity-time axes"), ("horizontal line above zero", "positive horizontal line")),
        make(10, "error", "graph-slope", level, graph("Constant positive velocity", "rising"),
             ("v-t axes", "velocity-time axes"), ("rising line", "positive slope")),
        make(11, "correct", "correct", accelerate, graph("Constant positive acceleration", "rising"),
             ("v-t axes", "velocity-time axes"), ("rising line", "positive slope")),
        make(12, "error", "graph-slope", accelerate, graph("Constant positive acceleration", "falling"),
             ("v-t axes", "velocity-time axes"), ("falling line", "negative slope")),
        make(13, "partial", "incomplete", level, graph("Start v-t plot for positive constant speed", None),
             ("v-t axes", "velocity-time axes"), ("no curve", "no data line")),
        make(14, "correct", "correct", lamp_on, circuit("Bulb on", "closed"),
             ("battery and bulb", "cell and lamp"), ("closed switch", "switch closed")),
        make(15, "error", "circuit-continuity", lamp_on, circuit("Bulb on", "open"),
             ("battery and bulb", "cell and lamp"), ("open switch", "switch open")),
        make(16, "correct", "correct", lamp_off, circuit("Bulb off", "open"),
             ("battery and bulb", "cell and lamp"), ("open switch", "switch open")),
        make(17, "partial", "incomplete", lamp_on, circuit("Start a circuit for a lit bulb", "unfinished"),
             ("battery and bulb", "cell and lamp"), ("unfinished switch", "switch contacts only")),
        make(18, "correct", "correct", mirror, reflection("Mirror reflection", 30),
             ("30 degree incident ray", "incidence 30 degrees"), ("30 degree reflected ray", "reflection 30 degrees")),
        make(19, "error", "reflection-angle", mirror, reflection("Mirror reflection", 60),
             ("30 degree incident ray", "incidence 30 degrees"), ("60 degree reflected ray", "reflection 60 degrees")),
        make(20, "partial", "incomplete", mirror, reflection("Start a reflection diagram", None),
             ("30 degree incident ray", "incidence 30 degrees"), ("no reflected ray", "reflected ray missing")),
    )


def synthetic_cases() -> tuple[Case, ...]:
    return _math_cases() + _chemistry_cases() + _physics_cases()

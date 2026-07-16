require 'wreckem/entity_manager'
require 'wreckem/component'

# Issue #4 -- Entity.find must not invent entities.
#
# Entity.find -> EntityManager#[] -> SequelStore#load_entity used to return a
# usable Entity for ANY id, including ids that never existed.  The phantom was
# not nil, responded to every message, and reported no components -- making it
# indistinguishable from a real entity that happens to have no components.
#
# The damage is that absence assertions become vacuous: a test asserting "the
# killed mob stays dead" (find it, assert no Breathing) passed against a completely
# wiped database, because a nonexistent mob has no Breathing either.
#
# The counterpart trap is over-fixing: an entity that genuinely exists but has
# had ONE component removed must still be findable and still report its others.

Tag       = Wreckem::Component.define_as_string
Vitality  = Wreckem::Component.define_as_int
Breathing = Wreckem::Component.define
Undead    = Wreckem::Component.define
Weapon    = Wreckem::Component.define_as_string
Corpse    = Wreckem::Component.define

describe "Wreckem::Entity.find existence" do
  # Run every example below against each storage backend; see spec_helper.rb.
  for_each_backend do
  before { @em = Wreckem::EntityManager.new }
  after { @em.destroy }

  context "ids that do not identify an entity" do
    it "should return nil for an id that has never existed" do
      # generate_id hands out a fresh id; nothing is persisted against it, so
      # no entity exists there.
      never_used = @em.generate_id

      expect(Wreckem::Entity.find(never_used)).to be_nil
    end

    it "should return nil for an unused id even when other entities exist" do
      Wreckem::Entity.is! { |e| e.has Tag.new("goblin") }
      never_used = @em.generate_id

      expect(@em.size).to eq(1)
      expect(Wreckem::Entity.find(never_used)).to be_nil
    end

    it "should return nil for a plausible but unused large id" do
      Wreckem::Entity.is! { |e| e.has Tag.new("goblin") }

      expect(Wreckem::Entity.find(999_999_999)).to be_nil
    end

    it "should return nil for nil" do
      expect(Wreckem::Entity.find(nil)).to be_nil
    end

    it "should return nil for an id from a since-destroyed store" do
      ghost_id = Wreckem::Entity.is! { |e| e.has Tag.new("doomed") }.id

      @em.destroy
      @em = Wreckem::EntityManager.new

      expect(@em.size).to eq(0)
      expect(Wreckem::Entity.find(ghost_id)).to be_nil
    end
  end

  context "entities that really exist" do
    it "should find a real entity and read its components back" do
      entity = Wreckem::Entity.is! do |e|
        e.has Tag.new("goblin")
        e.has Vitality.new(12)
        e.is Breathing
      end

      found = Wreckem::Entity.find(entity.id)

      expect(found).not_to be_nil
      expect(found).to be_a(Wreckem::Entity)
      expect(found).to eq(entity)
      expect(Tag.one(found).value).to eq("goblin")
      expect(Vitality.one(found).value).to eq(12)
      expect(found.is?(Breathing)).to eq(true)
    end

    it "should find an entity that carries only a single aspect component" do
      entity = Wreckem::Entity.is! { |e| e.is Undead }

      found = Wreckem::Entity.find(entity.id)

      expect(found).not_to be_nil
      expect(found.is?(Undead)).to eq(true)
    end
  end

  context "after an entity is deleted" do
    it "should return nil for the deleted entity's id" do
      entity = Wreckem::Entity.is! do |e|
        e.has Tag.new("kobold")
        e.is Breathing
      end
      id = entity.id

      expect(Wreckem::Entity.find(id)).not_to be_nil

      entity.delete

      expect(Wreckem::Entity.find(id)).to be_nil
    end

    it "should not resurrect a deleted entity while its neighbours survive" do
      doomed = Wreckem::Entity.is! { |e| e.has Tag.new("doomed"); e.is Breathing }
      keeper = Wreckem::Entity.is! { |e| e.has Tag.new("keeper"); e.is Breathing }

      doomed.delete

      expect(Wreckem::Entity.find(doomed.id)).to be_nil
      expect(Wreckem::Entity.find(keeper.id)).not_to be_nil
      expect(Tag.one(Wreckem::Entity.find(keeper.id)).value).to eq("keeper")
    end

    # This is the assertion the old phantom-entity behaviour made vacuous.
    # It must be able to tell "dead mob" apart from "mob that was never here".
    it "should make a 'stays dead' assertion meaningful rather than vacuous" do
      mob = Wreckem::Entity.is! { |e| e.has Tag.new("hydra"); e.is Breathing }
      id = mob.id

      mob.delete

      dead = Wreckem::Entity.find(id)

      # The entity is gone -- not merely a husk that stopped Breathing.
      expect(dead).to be_nil
    end
  end

  context "removing one component must not delete the entity (over-fix guard)" do
    it "should still find a mob whose Breathing component was removed" do
      mob = Wreckem::Entity.is! do |e|
        e.has Tag.new("hydra")
        e.has Vitality.new(30)
        e.is Breathing
      end

      Breathing.one(mob).delete

      found = Wreckem::Entity.find(mob.id)

      expect(found).not_to be_nil
      expect(found).to eq(mob)
    end

    it "should still report the other components of a mob that lost its Breathing" do
      mob = Wreckem::Entity.is! do |e|
        e.has Tag.new("hydra")
        e.has Vitality.new(30)
        e.is Breathing
      end

      Breathing.one(mob).delete

      found = Wreckem::Entity.find(mob.id)

      expect(found.is?(Breathing)).to eq(false)
      expect(Tag.one(found).value).to eq("hydra")
      expect(Vitality.one(found).value).to eq(30)
      expect(found.components.size).to eq(2)
    end

    it "should keep a killed-but-not-deleted mob countable and enumerable" do
      mob = Wreckem::Entity.is! do |e|
        e.has Tag.new("hydra")
        e.is Breathing
      end

      Breathing.one(mob).delete
      mob.is Corpse

      expect(@em.size).to eq(1)
      expect(@em.to_a.map(&:id)).to eq([mob.id])

      found = Wreckem::Entity.find(mob.id)
      expect(found).not_to be_nil
      expect(found.is?(Corpse)).to eq(true)
      expect(found.is?(Breathing)).to eq(false)
    end

    it "should still find an entity after swapping one component for another" do
      mob = Wreckem::Entity.is! do |e|
        e.has Tag.new("orc")
        e.has Weapon.new("axe")
      end

      Weapon.one(mob).delete
      mob.has Weapon.new("sword")

      found = Wreckem::Entity.find(mob.id)

      expect(found).not_to be_nil
      expect(Weapon.one(found).value).to eq("sword")
      expect(Tag.one(found).value).to eq("orc")
    end
  end

  # Characterisation, not endorsement.  Under this data model an entity has no
  # row of its own, so an entity whose LAST component is removed is physically
  # indistinguishable from one that never existed.  Pinning the behaviour so a
  # future change to the model is a deliberate, visible decision.
  context "an entity stripped of every component (data-model limitation)" do
    it "should become unfindable, since nothing records its existence" do
      mob = Wreckem::Entity.is! { |e| e.has Tag.new("solo") }

      Tag.one(mob).delete

      expect(Wreckem::Entity.find(mob.id)).to be_nil
      expect(@em.size).to eq(0)
    end
  end
  end
end

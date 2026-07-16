require 'set'
require 'wreckem/entity'

module Wreckem
  ##
  # An in-memory backend that speaks the same contract SequelStore does, so a
  # game can run entirely in RAM and mirror to disk with save/restore instead of
  # paying a SQL round-trip on every component access.
  #
  # It deliberately mirrors SequelStore's *row* model rather than holding live
  # component objects. An entity has no record of its own -- it is just an id
  # that component rows point at via eid -- and every read rehydrates a fresh
  # component from its stored data. That freshness is load-bearing, not an
  # implementation detail: `component.update(v)` must change the caller's copy
  # without touching the store until `save`, which only holds if each `one`/`many`
  # hands back a new instance. Holding the live object would quietly break it.
  class MemoryStore
    def initialize
      @rows = {}          # component_id => {id:, eid:, name:, type:, value:}
      @ids_by_eid = {}    # eid            => Set<component_id>
      @ids_by_class = {}  # class name     => Set<component_id>
      @entity_id = 0      # next entity id (SequelStore's sequence starts at 0)
      @component_id = 0   # last component id (SQLite rowid starts at 1)
    end

    ##
    # Entity ids come from here; component ids are assigned in insert_component.
    # Kept out of any transaction because the worst case is a few unused ids.
    def generate_id
      id = @entity_id
      @entity_id += 1
      id
    end

    ##
    # Store a snapshot of the component and stamp it with its new id. Aspects
    # carry no value, matching how SequelStore leaves their data column unused.
    def insert_component(component)
      @component_id += 1
      id = @component_id
      type = component.type
      @rows[id] = {
        id: id,
        eid: component.eid,
        name: component.class.name,
        type: type,
        value: (type == :aspect ? nil : component.value)
      }
      (@ids_by_eid[component.eid] ||= Set.new) << id
      (@ids_by_class[component.class.name] ||= Set.new) << id
      component.id = id
    end

    def update_component(component)
      row = @rows[component.id]
      return component unless row

      row[:eid] = component.eid
      row[:value] = component.value unless row[:type] == :aspect
      component
    end

    def delete_component(component, *)
      row = @rows.delete(component.id)
      forget(row) if row
    end

    ##
    # Deletes the entity: every row pointing at its eid. to_a first, since forget
    # mutates the set we would otherwise be iterating.
    def delete_entity(entity, *)
      ids = @ids_by_eid[entity.id]
      if ids
        ids.to_a.each do |cid|
          row = @rows.delete(cid)
          forget(row) if row
        end
      end
      entity
    end

    def load_components_of_entity(entity_id, &block)
      hydrate(@ids_by_eid[entity_id]) { |cid| instantiate(@rows[cid]) }.then do |arr|
        block ? arr.each(&block) : arr.enum_for(:each)
      end
    end

    def load_components_from_class(component_class, &block)
      hydrate(@ids_by_class[component_class.name]) { |cid| instantiate(@rows[cid]) }.then do |arr|
        block ? arr.each(&block) : arr.enum_for(:each)
      end
    end

    ##
    # One entity per matching row, not deduplicated -- SequelStore builds an
    # Entity per row here too, so a doubled component yields a doubled entity.
    def load_entities_for_component_class(component_class, &block)
      hydrate(@ids_by_class[component_class.name]) { |cid| Entity.new_protected(@rows[cid][:eid]) }.then do |arr|
        block ? arr.each(&block) : arr.enum_for(:each)
      end
    end

    ##
    # The in-memory analog of SequelStore's join-on-shared-eid intersects. Find
    # the eids present in every requested class, apply the optional trailing
    # where-hash, and yield one [c0, c1, ...] list per surviving entity.
    #
    # Comparison is by string value with a leading '!' meaning "not", matching
    # how SequelStore renders conditions into SQL. Boolean columns are the one
    # place the backends can disagree: SQLite stores 1/0 while a Ruby bool stays
    # true/false, so a `{:value => 0}` idiom that leans on SQLite affinity is a
    # storage-specific quirk, not part of this contract.
    def load_components_from_classes(component_classes, &block)
      classes = component_classes.dup
      where_hash = classes.pop if classes.last.is_a?(Hash)

      eid_sets = classes.map { |c| eids_for_class(c) }
      candidates = eid_sets.reduce { |a, b| a & b } || Set.new

      results = candidates.each_with_object([]) do |eid, acc|
        next unless passes_where?(eid, classes, where_hash)
        list = classes.map { |c| first_component(eid, c) }
        acc << list unless list.any?(&:nil?)
      end

      block ? results.each(&block) : results.enum_for(:each)
    end

    ##
    # An entity exists when something refers to it -- matching SequelStore after
    # the honest-find fix. An id nothing points at is not an entity.
    def load_entity(entity_id)
      return nil unless entity_id
      ids = @ids_by_eid[entity_id]
      return nil if ids.nil? || ids.empty?

      Entity.new_protected(entity_id)
    end

    def entities
      @ids_by_eid.keys.map { |eid| Entity.new_protected(eid) }
    end

    ##
    # Explicit teardown. SequelStore drops its tables; the in-memory store just
    # forgets everything.
    def destroy
      initialize
    end

    def self.restore
      File.open("db", "rb") { |f| Marshal.load(f.read) }
    rescue
      new
    end

    ##
    # The whole store marshals cleanly because rows hold only primitives, class
    # *names*, and type symbols -- never a live component or class object.
    def save
      File.open("db", "wb") { |f| f.write Marshal.dump(self) }
    end

    ##
    # No-op, like SequelStore: operations already apply immediately, and the
    # Batch in entity.rb is what groups a construction before saving it.
    def transaction
      yield
    end

    private

    ##
    # Map a stored id set to fresh objects. Reads never create the set (that is
    # insert_component's job), so probing a missing eid/class cannot leave an
    # empty set behind and quietly grow the store.
    def hydrate(ids)
      return [] unless ids
      ids.map { |cid| yield cid }
    end

    def instantiate(row)
      component_class = name_to_class(row[:name])
      component = row[:type] == :aspect ? component_class.new : component_class.new(row[:value])
      component.id = row[:id]
      component.eid = row[:eid]
      component
    end

    ##
    # Drop a row from both indexes, pruning a set once it empties so entities and
    # #load_entity stop seeing an eid the moment its last component goes.
    def forget(row)
      prune(@ids_by_eid, row[:eid], row[:id])
      prune(@ids_by_class, row[:name], row[:id])
    end

    def prune(index, key, id)
      set = index[key]
      return unless set

      set.delete(id)
      index.delete(key) if set.empty?
    end

    def eids_for_class(component_class)
      ids = @ids_by_class[component_class.name]
      return Set.new unless ids

      ids.each_with_object(Set.new) { |cid, s| s << @rows[cid][:eid] }
    end

    def first_component(eid, component_class)
      ids = @ids_by_eid[eid]
      return nil unless ids

      cid = ids.find { |i| @rows[i][:name] == component_class.name }
      cid ? instantiate(@rows[cid]) : nil
    end

    def passes_where?(eid, classes, where_hash)
      return true unless where_hash

      classes.all? do |c|
        conds = where_hash[c.name.to_sym] || where_hash[c.name.downcase.to_sym]
        next true unless conds

        ok = true
        ok &&= matches?(first_component(eid, c)&.value, conds[:value]) if conds.key?(:value)
        ok &&= matches?(eid, conds[:eid]) if conds.key?(:eid)
        ok
      end
    end

    def matches?(actual, target)
      negate = target.is_a?(String) && target.include?('!')
      wanted = negate ? target.delete('!') : target
      equal = actual.to_s == wanted.to_s
      negate ? !equal : equal
    end

    def name_to_class(class_name)
      class_name.split("::").inject(Object) do |parent, name|
        parent.const_get(name)
      end
    end
  end
end
